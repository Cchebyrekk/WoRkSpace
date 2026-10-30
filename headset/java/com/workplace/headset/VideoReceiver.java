package com.workplace.headset;

import android.graphics.ImageFormat;
import android.hardware.HardwareBuffer;
import android.media.Image;
import android.media.ImageReader;
import android.media.MediaCodec;
import android.media.MediaFormat;
import android.view.Surface;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.util.ArrayDeque;
import java.util.HashMap;
import java.util.TreeMap;

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

	/** Screen id (chosen by the caller) -> its receiver. */
	private static final HashMap<Integer, VideoReceiver> receivers = new HashMap<>();
	/**
	 * The PC's capture clock minus this headset's (System.nanoTime in µs), slice
	 * o7: each receiver pings the PC's stream every CLOCK_PING_MS; of the newest
	 * CLOCK_SAMPLES answers (all receivers) the one with the shortest round trip
	 * sets it. Until the first answer no latency is measured.
	 */
	private static final long CLOCK_PING_MS = 1000;
	private static final int CLOCK_SAMPLES = 30;
	private static final ArrayDeque<long[]> clockSamples = new ArrayDeque<>();
	private static volatile long clockOffsetUs;
	private static volatile boolean clockKnown;
	private static volatile double clockErrorMs = -1;
	/** Latency of new pictures since the last latencyReport, summed over every receiver. */
	private static final Object latencyLock = new Object();
	private static long latencyCount;
	private static double arrivedSumMs;
	private static double shownSumMs;
	private static double shownMaxMs;
	private static double decodeSumMs;
	private static double decodeMaxMs;

	private Thread thread;
	private Socket socket;
	private volatile boolean running;
	private volatile String status = "остановлен";
	private volatile long framesReceived;
	private volatile long framesShown;
	private volatile long bytesReceived;
	private volatile double decodeMs;
	/** Capture time of the last picture counted in the latency (decoder thread only). */
	private long lastCapturedUs = -1;
	private long firstShownNanos;
	private static final long WARMUP_NS = 1_500_000_000L;
	private volatile int width;
	private volatile int height;
	/** The decoder could not be made or started (the Quest ran out of decoders), not the network. */
	private volatile boolean decoderFailed;
	/** Texture mode (surface null): where the decoder puts frames, and the frames held. */
	private ImageReader reader;
	private Image frame;
	private Image previousFrame;
	private long framePointer;
	/**
	 * Branch pc-render: the pose id the eyes' picture was drawn with, by its
	 * presentation time (µs), for frames gone to the reader; and that of the frame
	 * textureFrame returned last.
	 */
	private final TreeMap<Long, Integer> posesByTime = new TreeMap<>();
	private volatile int framePose;
	/**
	 * The decoder's buffer, which can be wider than the picture (3680 for 3664,
	 * 30.10.2026): sampled whole, the picture shrank towards its left edge.
	 */
	private volatile int bufferWidth;
	private volatile int bufferHeight;
	/** EGLImage of each of the reader's buffers (by HardwareBuffer id), made once. */
	private final HashMap<Long, Long> images = new HashMap<>();

	private VideoReceiver() {
	}

	/**
	 * Like start, but the frames go into an ImageReader instead of a surface; Godot
	 * takes each one through textureFrame (convex screens, slice o5d).
	 */
	public static synchronized void startTexture(int id, String host, int port) {
		start(id, null, host, port);
	}

	/**
	 * The newest decoded frame of a texture receiver as an EGLImage for Godot's
	 * ExternalTexture (Compatibility renderer), 0 if none yet; call on Godot's thread. The frame and the one before it
	 * stay open (Godot may still be drawing it); older ones are let go.
	 */
	public static long textureFrame(int id) {
		VideoReceiver receiver = get(id);
		return receiver == null ? 0 : receiver.takeFrame();
	}

	/** The pose id of the frame textureFrame returned last (eyes' stream, branch pc-render). */
	public static int textureFramePose(int id) {
		VideoReceiver receiver = get(id);
		return receiver == null ? 0 : receiver.framePose;
	}

	public static int textureWidth(int id) {
		VideoReceiver receiver = get(id);
		return receiver == null ? 0 : receiver.width;
	}

	public static int textureHeight(int id) {
		VideoReceiver receiver = get(id);
		return receiver == null ? 0 : receiver.height;
	}

	/** The width of the buffer textureFrame's picture is in (0 before the first). */
	public static int textureBufferWidth(int id) {
		VideoReceiver receiver = get(id);
		return receiver == null ? 0 : receiver.bufferWidth;
	}

	public static int textureBufferHeight(int id) {
		VideoReceiver receiver = get(id);
		return receiver == null ? 0 : receiver.bufferHeight;
	}

	/** Starts receiving into `surface`; a receiver already running under `id` is stopped first. */
	public static synchronized void start(int id, Surface surface, String host, int port) {
		VideoReceiver previous = receivers.remove(id);
		Thread previousThread = null;
		if (previous != null) {
			previous.halt();
			previousThread = previous.thread;
		}
		VideoReceiver receiver = new VideoReceiver();
		receiver.running = true;
		receiver.status = "подключаюсь";
		Thread waitFor = previousThread;
		receiver.thread = new Thread(() -> {
			// The surface takes one decoder at a time: the old one lets go first.
			if (waitFor != null) {
				try {
					waitFor.join(2000);
				} catch (InterruptedException ignored) {
					return;
				}
			}
			receiver.run(surface, host, port);
		}, "WoRkPlaceVideo" + id);
		receivers.put(id, receiver);
		receiver.thread.start();
	}

	public static synchronized void stop(int id) {
		VideoReceiver receiver = receivers.remove(id);
		if (receiver != null) {
			receiver.halt();
		}
	}

	public static synchronized void stopAll() {
		for (VideoReceiver receiver : receivers.values()) {
			receiver.halt();
		}
		receivers.clear();
	}

	private static synchronized VideoReceiver get(int id) {
		return receivers.get(id);
	}

	/** Whether the receiver under `id` still receives (false once its stream ended or failed). */
	public static boolean decoderFailed(int id) {
		VideoReceiver receiver = get(id);
		return receiver != null && receiver.decoderFailed;
	}

	public static boolean isAlive(int id) {
		VideoReceiver receiver = get(id);
		return receiver != null && receiver.running;
	}

	/** What the receiver is doing, or why it stopped. */
	public static String status(int id) {
		VideoReceiver receiver = get(id);
		return receiver == null ? "нет" : receiver.status;
	}

	public static long framesShown(int id) {
		VideoReceiver receiver = get(id);
		return receiver == null ? 0 : receiver.framesShown;
	}

	public static long bytesReceived(int id) {
		VideoReceiver receiver = get(id);
		return receiver == null ? 0 : receiver.bytesReceived;
	}

	/** The last frame's time from entering the decoder to being shown. */
	public static double decodeMs(int id) {
		VideoReceiver receiver = get(id);
		return receiver == null ? 0 : receiver.decodeMs;
	}

	/** How far off the clock may be (half the best round trip), -1 until set. */
	public static double clockErrorMs() {
		return clockErrorMs;
	}

	/** A message to the PC's stream: 1 — our clock (a ping), 2 — frames received. */
	private static void tell(OutputStream toPc, int type, long value) throws java.io.IOException {
		byte[] message = new byte[9];
		message[0] = (byte) type;
		for (int i = 0; i < 8; i++) {
			message[1 + i] = (byte) (value >>> (56 - 8 * i));
		}
		toPc.write(message);
		toPc.flush();
	}

	private static void addClockSample(long sentUs, long pcUs) {
		long backUs = System.nanoTime() / 1000;
		synchronized (clockSamples) {
			clockSamples.addLast(new long[] { backUs - sentUs, pcUs - (sentUs + backUs) / 2 });
			if (clockSamples.size() > CLOCK_SAMPLES) {
				clockSamples.removeFirst();
			}
			long[] best = null;
			for (long[] sample : clockSamples) {
				if (best == null || sample[0] < best[0]) {
					best = sample;
				}
			}
			clockOffsetUs = best[1];
			clockErrorMs = best[0] / 2000.0;
			clockKnown = true;
		}
	}

	/**
	 * What the new pictures went through since the last call, over every receiver:
	 * "count arrived shown shownMax decode decodeMax" (ms, averages unless max;
	 * arrived and shown are from the PC capturing the picture to it being read
	 * from the network / leaving the decoder). Empty while the clock is not set.
	 */
	public static String latencyReport() {
		synchronized (latencyLock) {
			String report = "";
			if (clockKnown && latencyCount > 0) {
				report = latencyCount + " " + arrivedSumMs / latencyCount + " " + shownSumMs / latencyCount + " "
						+ shownMaxMs + " " + decodeSumMs / latencyCount + " " + decodeMaxMs;
			}
			latencyCount = 0;
			arrivedSumMs = 0;
			shownSumMs = 0;
			shownMaxMs = 0;
			decodeSumMs = 0;
			decodeMaxMs = 0;
			return report;
		}
	}

	private static void addLatency(double arrivedMs, double shownMs, double decodeMs) {
		synchronized (latencyLock) {
			latencyCount++;
			arrivedSumMs += arrivedMs;
			shownSumMs += shownMs;
			shownMaxMs = Math.max(shownMaxMs, shownMs);
			decodeSumMs += decodeMs;
			decodeMaxMs = Math.max(decodeMaxMs, decodeMs);
		}
	}

	/** Does not wait: closing the socket ends the thread, which releases the decoder. */
	private void halt() {
		running = false;
		closeSocket();
	}

	private synchronized void closeSocket() {
		if (socket != null) {
			try {
				socket.close();
			} catch (Exception ignored) {
			}
			socket = null;
		}
	}

	private synchronized long takeFrame() {
		if (reader == null) {
			return framePointer;
		}
		Image image;
		try {
			image = reader.acquireLatestImage();
			if (image != null) {
				Integer pose = posesByTime.get(image.getTimestamp() / 1000);
				if (pose != null) {
					framePose = pose;
				}
				posesByTime.headMap(image.getTimestamp() / 1000).clear();
			}
		} catch (IllegalStateException e) {
			return framePointer;
		}
		if (image == null) {
			return framePointer;
		}
		if (previousFrame != null) {
			previousFrame.close();
		}
		previousFrame = frame;
		frame = image;
		HardwareBuffer buffer = image.getHardwareBuffer();
		if (buffer == null) {
			return framePointer;
		}
		bufferWidth = buffer.getWidth();
		bufferHeight = buffer.getHeight();
		Long made = images.get(buffer.getId());
		if (made == null) {
			made = HardwareBuffers.image(buffer);
			if (made != 0) {
				images.put(buffer.getId(), made);
			}
		}
		buffer.close();
		if (made != 0) {
			framePointer = made;
		}
		return framePointer;
	}

	private synchronized void closeFrames() {
		if (frame != null) {
			frame.close();
			frame = null;
		}
		if (previousFrame != null) {
			previousFrame.close();
			previousFrame = null;
		}
		if (reader != null) {
			reader.close();
			reader = null;
		}
		for (long image : images.values()) {
			HardwareBuffers.destroy(image);
		}
		images.clear();
		framePointer = 0;
	}

	private void run(Surface surface, String host, int port) {
		MediaCodec decoder = null;
		try {
			Socket connection = new Socket();
			synchronized (this) {
				socket = connection;
			}
			connection.setTcpNoDelay(true);
			connection.setReceiveBufferSize(1 << 20);
			connection.connect(new InetSocketAddress(host, port), CONNECT_TIMEOUT_MS);
			DataInputStream input = new DataInputStream(new BufferedInputStream(connection.getInputStream(), 1 << 16));
			OutputStream toPc = connection.getOutputStream();
			long nextClockPing = 0;

			byte[] magic = new byte[4];
			input.readFully(magic);
			if (magic[0] != 'W' || magic[1] != 'R' || magic[2] != 'K' || magic[3] != 'V') {
				throw new IllegalStateException("это не видео WoRkPlace");
			}
			int version = input.readInt();
			width = input.readInt();
			height = input.readInt();
			int fps = input.readInt();
			// 3, 4: the PC-drawn eyes (branch pc-render) with a pose id per frame; 4 is HEVC.
			boolean withPose = version == 3 || version == 4;
			String mime = version == 4 ? MediaFormat.MIMETYPE_VIDEO_HEVC : MediaFormat.MIMETYPE_VIDEO_AVC;
			if (version != 2 && !withPose) {
				throw new IllegalStateException("версия видео " + version);
			}

			MediaFormat format = MediaFormat.createVideoFormat(mime, width, height);
			format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
			// No KEY_PRIORITY 0 / KEY_OPERATING_RATE: with them the Quest 3S reserved
			// realtime capacity and refused the 7th decoder (NO_MEMORY, slice o4).
			// Qualcomm's own switch for the same; unknown keys are ignored.
			format.setInteger("vendor.qti-ext-dec-low-latency.enable", 1);
			try {
				decoder = MediaCodec.createDecoderByType(mime);
				Surface output = surface;
				if (output == null) {
					// Texture mode: 4 buffers, 2 held for Godot, 2 for the decoder.
					synchronized (this) {
						reader = ImageReader.newInstance(width, height, ImageFormat.PRIVATE, 4,
								HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE);
					}
					output = reader.getSurface();
				}
				decoder.configure(format, output, null, 0);
				decoder.start();
			} catch (Exception e) {
				decoderFailed = true;
				throw e;
			}
			status = "показываю " + width + "×" + height;

			MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
			HashMap<Long, long[]> queuedAt = new HashMap<>();
			byte[] frame = new byte[1 << 20];
			while (running) {
				long nowMs = System.nanoTime() / 1_000_000;
				if (nowMs >= nextClockPing) {
					nextClockPing = nowMs + CLOCK_PING_MS;
					tell(toPc, 1, System.nanoTime() / 1000);
				}
				int length = input.readInt();
				long time = input.readLong();
				long capturedUs = input.readLong();
				long pose = withPose ? input.readInt() & 0xffffffffL : 0;
				int flags = input.readByte();
				if ((flags & 2) != 0) {
					addClockSample(time, capturedUs); // the clock's answer: our time, the PC's
					continue;
				}
				boolean key = (flags & 1) != 0;
				if (length <= 0 || length > MAX_FRAME_BYTES) {
					throw new IllegalStateException("кадр " + length + " байт");
				}
				if (frame.length < length) {
					frame = new byte[length * 2];
				}
				input.readFully(frame, 0, length);
				// The PC keeps only a few frames on the way (slice o7): it hears of each one here.
				tell(toPc, 2, framesReceived + 1);
				long arrived = System.nanoTime();
				framesReceived++;
				bytesReceived += length + 21;

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
				queuedAt.put(time, new long[] { System.nanoTime(), arrived, capturedUs, pose });
				decoder.queueInputBuffer(index, 0, length, time, key ? MediaCodec.BUFFER_FLAG_KEY_FRAME : 0);
				drain(decoder, info, queuedAt);
			}
		} catch (Exception e) {
			if (running) {
				status = "ошибка: " + e;
			}
		} finally {
			if (decoder != null) {
				try {
					decoder.stop();
				} catch (Exception ignored) {
				}
				decoder.release();
			}
			closeFrames();
			closeSocket();
			if (running) {
				running = false;
			} else {
				status = "остановлен";
			}
		}
	}

	private void drain(MediaCodec decoder, MediaCodec.BufferInfo info, HashMap<Long, long[]> queuedAt) {
		int index;
		while ((index = decoder.dequeueOutputBuffer(info, 0)) != MediaCodec.INFO_TRY_AGAIN_LATER) {
			if (index < 0) {
				continue; // The output format or buffers changed; nothing to show yet.
			}
			long[] queued = queuedAt.remove(info.presentationTimeUs);
			if (queued != null) {
				long now = System.nanoTime();
				decodeMs = (now - queued[0]) / 1e6;
				// A picture encoded again (to push the decoder, or the refresh) keeps
				// its capture time: only its first frame counts.
				// Neither a picture from before this connection (0) nor the first
				// WARMUP_NS after the first frame out: a new decoder starting held
				// frames up to 3 s, which is no latency of the link (slice o7).
				if (firstShownNanos == 0) {
					firstShownNanos = now;
				}
				if (clockKnown && queued[2] != 0 && queued[2] != lastCapturedUs) {
					lastCapturedUs = queued[2];
					long offset = clockOffsetUs;
					if (now - firstShownNanos > WARMUP_NS) {
						addLatency((queued[1] / 1000 + offset - queued[2]) / 1e3, (now / 1000 + offset - queued[2]) / 1e3,
								decodeMs);
					}
				}
			}
			if (queued != null && reader != null) {
				synchronized (this) {
					posesByTime.put(info.presentationTimeUs, (int) queued[3]);
					while (posesByTime.size() > 64) {
						posesByTime.pollFirstEntry();
					}
				}
			}
			decoder.releaseOutputBuffer(index, true);
			framesShown++;
		}
		if (queuedAt.size() > 120) {
			queuedAt.clear(); // Frames the decoder dropped never come out.
		}
	}
}
