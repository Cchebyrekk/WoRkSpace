package com.workplace.headset;

import android.media.MediaCodec;
import android.media.MediaFormat;
import android.view.Surface;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.util.HashMap;

/**
 * The headset side of the own video link (slice o3): receives the PC's H.264
 * stream over TCP and decodes it with MediaCodec straight into a Surface (the
 * one of an OpenXR composition layer). Runs on its own thread; GDScript only
 * starts, stops and reads the counters, through JavaClassWrapper. The stream
 * format is described at StreamBackend in native/src/win_backend.h.
 */
public final class VideoReceiver {
	private static final int CONNECT_TIMEOUT_MS = 3000;
	private static final int MAX_FRAME_BYTES = 16 << 20;

	private static Thread thread;
	private static Socket socket;
	private static volatile boolean running;
	private static volatile String status = "остановлен";
	private static volatile long framesReceived;
	private static volatile long framesShown;
	private static volatile long bytesReceived;
	private static volatile double decodeMs;
	private static volatile int width;
	private static volatile int height;

	private VideoReceiver() {
	}

	public static synchronized void start(Surface surface, String host, int port) {
		stop();
		running = true;
		status = "подключаюсь";
		framesReceived = 0;
		framesShown = 0;
		bytesReceived = 0;
		decodeMs = 0;
		thread = new Thread(() -> run(surface, host, port), "WoRkPlaceVideo");
		thread.start();
	}

	public static synchronized void stop() {
		running = false;
		closeSocket();
		if (thread != null) {
			try {
				thread.join(2000);
			} catch (InterruptedException ignored) {
				Thread.currentThread().interrupt();
			}
			thread = null;
		}
	}

	public static boolean isRunning() {
		return running;
	}

	/** What the receiver is doing, or why it stopped. */
	public static String status() {
		return status;
	}

	public static long framesReceived() {
		return framesReceived;
	}

	public static long framesShown() {
		return framesShown;
	}

	public static long bytesReceived() {
		return bytesReceived;
	}

	/** The last frame's time from entering the decoder to being shown. */
	public static double decodeMs() {
		return decodeMs;
	}

	public static int width() {
		return width;
	}

	public static int height() {
		return height;
	}

	private static synchronized void closeSocket() {
		if (socket != null) {
			try {
				socket.close();
			} catch (Exception ignored) {
			}
			socket = null;
		}
	}

	private static void run(Surface surface, String host, int port) {
		MediaCodec decoder = null;
		try {
			Socket connection = new Socket();
			synchronized (VideoReceiver.class) {
				socket = connection;
			}
			connection.setTcpNoDelay(true);
			connection.setReceiveBufferSize(1 << 20);
			connection.connect(new InetSocketAddress(host, port), CONNECT_TIMEOUT_MS);
			DataInputStream input = new DataInputStream(new BufferedInputStream(connection.getInputStream(), 1 << 16));

			byte[] magic = new byte[4];
			input.readFully(magic);
			if (magic[0] != 'W' || magic[1] != 'R' || magic[2] != 'K' || magic[3] != 'V') {
				throw new IllegalStateException("это не видео WoRkPlace");
			}
			int version = input.readInt();
			width = input.readInt();
			height = input.readInt();
			int fps = input.readInt();
			if (version != 1) {
				throw new IllegalStateException("версия видео " + version);
			}

			MediaFormat format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height);
			format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
			format.setInteger(MediaFormat.KEY_PRIORITY, 0);
			format.setInteger(MediaFormat.KEY_OPERATING_RATE, fps);
			// Qualcomm's own switch for the same; unknown keys are ignored.
			format.setInteger("vendor.qti-ext-dec-low-latency.enable", 1);
			decoder = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
			decoder.configure(format, surface, null, 0);
			decoder.start();
			status = "показываю " + width + "×" + height;

			MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
			HashMap<Long, Long> queuedAt = new HashMap<>();
			byte[] frame = new byte[1 << 20];
			while (running) {
				int length = input.readInt();
				long time = input.readLong();
				boolean key = (input.readByte() & 1) != 0;
				if (length <= 0 || length > MAX_FRAME_BYTES) {
					throw new IllegalStateException("кадр " + length + " байт");
				}
				if (frame.length < length) {
					frame = new byte[length * 2];
				}
				input.readFully(frame, 0, length);
				framesReceived++;
				bytesReceived += length + 13;

				int index;
				while ((index = decoder.dequeueInputBuffer(5000)) < 0) {
					drain(decoder, info, queuedAt);
					if (!running) {
						return;
					}
				}
				ByteBuffer buffer = decoder.getInputBuffer(index);
				buffer.clear();
				buffer.put(frame, 0, length);
				queuedAt.put(time, System.nanoTime());
				decoder.queueInputBuffer(index, 0, length, time, key ? MediaCodec.BUFFER_FLAG_KEY_FRAME : 0);
				drain(decoder, info, queuedAt);
			}
		} catch (Exception e) {
			if (running) {
				status = "ошибка: " + e.getMessage();
			}
		} finally {
			if (decoder != null) {
				try {
					decoder.stop();
				} catch (Exception ignored) {
				}
				decoder.release();
			}
			closeSocket();
			if (running) {
				running = false;
			} else {
				status = "остановлен";
			}
		}
	}

	private static void drain(MediaCodec decoder, MediaCodec.BufferInfo info, HashMap<Long, Long> queuedAt) {
		int index;
		while ((index = decoder.dequeueOutputBuffer(info, 0)) != MediaCodec.INFO_TRY_AGAIN_LATER) {
			if (index < 0) {
				continue; // The output format or buffers changed; nothing to show yet.
			}
			Long queued = queuedAt.remove(info.presentationTimeUs);
			if (queued != null) {
				decodeMs = (System.nanoTime() - queued) / 1e6;
			}
			decoder.releaseOutputBuffer(index, true);
			framesShown++;
		}
		if (queuedAt.size() > 120) {
			queuedAt.clear(); // Frames the decoder dropped never come out.
		}
	}
}
