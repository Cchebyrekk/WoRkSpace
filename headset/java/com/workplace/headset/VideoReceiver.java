package com.workplace.headset;

import android.graphics.ImageFormat;
import android.hardware.HardwareBuffer;
import android.hardware.SyncFence;
import android.media.Image;
import android.media.ImageReader;
import android.media.MediaCodec;
import android.media.MediaFormat;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Build;
import android.view.Surface;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.util.ArrayDeque;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
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
	private volatile int videoVersion;
	/** The decoder could not be made or started (the Quest ran out of decoders), not the network. */
	private volatile boolean decoderFailed;
	/** Texture mode (surface null): where the decoder puts frames, and the frames held. */
	private ImageReader reader;
	private HandlerThread imageThread;
	private final Object imageReady = new Object();
	private Image frame;
	private Image previousFrame;
	private long framePointer;
	/**
	 * Branch pc-render: the pose id the eyes' picture was drawn with, by its
	 * presentation time (µs), for frames gone to the reader; and that of the frame
	 * textureFrame returned last.
	 */
	private final TreeMap<Long, Integer> posesByTime = new TreeMap<>();
	private final TreeMap<Long, long[]> timingsByTime = new TreeMap<>();
	private final FrameTimings timings = new FrameTimings();
	private long lastTakenNs;
	private int pendingPeak;
	private volatile int framePose;
	private volatile long frameTimeUs;
	private volatile long frameCapturedUs;
	/**
	 * The decoder's buffer, which can be wider than the picture (3680 for 3664,
	 * 30.10.2026): sampled whole, the picture shrank towards its left edge.
	 */
	private volatile int bufferWidth;
	private volatile int bufferHeight;
	/** EGLImage of each of the reader's buffers (by HardwareBuffer id), made once. */
	private final HashMap<Long, Long> images = new HashMap<>();
	/**
	 * Paced texture mode (slice q1, a PC VR game's eyes): Wi-Fi brings frames
	 * unevenly, two at once and then none; showing only the newest skipped one
	 * and repeated the next, and the game's motion stuttered (04.11.2026). Paced,
	 * each Godot frame takes the next frame in order, as WiVRn and ALVR show them
	 * one per display frame. Released to the reader as soon as decoded, a fifth of
	 * them still vanished on the way to it when two came close together (716 out
	 * of the decoder, 585 shown). So paced frames wait in the decoder (pending:
	 * output buffer indices) and each Godot frame releases one to the reader and
	 * originally took the one released the frame before. q4 releases it before
	 * acquiring, waits at most 1 ms for ImageReader notification and checks the
	 * producer fence on API 33+: no forced extra display frame. Older Android
	 * retains the previous ordering. Excess pending buffers are dropped.
	 */
	private volatile boolean paced;
	private volatile boolean comparisonTest = true;
	private long pacedNew;
	private long pacedSkipped;
	private long pacedRepeated;
	private long reportedReceived;
	private long reportedShown;
	private long reportedAtNs = System.nanoTime();
	/**
	 * Paced: the decoder's frames are taken by a thread of their own as soon as
	 * they are out; taken only when the next frame came in from the network,
	 * they waited a frame and came out two at once.
	 */
	private volatile boolean outputStop;
	private Thread outputThread;
	private final ArrayDeque<Integer> pending = new ArrayDeque<>();
	private MediaCodec pendingCodec;
	/** Decoded frames left waiting at most: older ones are dropped (latency). */
	private volatile int pendingMax = 2;

	private VideoReceiver() {
	}

	/**
	 * Like start, but the frames go into an ImageReader instead of a surface; Godot
	 * takes each one through textureFrame (convex screens, slice o5d).
	 */
	public static synchronized void startTexture(int id, String host, int port) {
		start(id, null, host, port);
	}

	/** startTexture, with the frames taken in order, one per call (see paced). */
	public static synchronized void startTexturePaced(int id, String host, int port) {
		startInternal(id, null, host, port, true);
	}

	/** Extra decoded frames held behind the next one to release (0 = newest). */
	public static void configurePacing(int id, int extraFrames) {
		VideoReceiver receiver = get(id);
		if (receiver != null) receiver.pendingMax = Math.max(0, Math.min(2, extraFrames)) + 1;
	}

	public static void configureComparison(int id, int profile) {
		VideoReceiver receiver = get(id);
		if(receiver != null) {
			receiver.comparisonTest = profile != 0;
		}
	}

	/** New, skipped and repeated frames of a paced receiver since the last call. */
	public static String pacingReport(int id) {
		VideoReceiver receiver = get(id);
		if (receiver == null) {
			return "";
		}
		synchronized (receiver) {
			long received = receiver.framesReceived;
			long shown = receiver.framesShown;
			long now = System.nanoTime();
			double seconds = Math.max(.001, (now - receiver.reportedAtNs) / 1e9);
			String report = "принято " + (received - receiver.reportedReceived) + ", из декодера "
					+ (shown - receiver.reportedShown) + ", показано новых " + receiver.pacedNew + ", пропущено "
					+ receiver.pacedSkipped + ", без нового " + receiver.pacedRepeated;
			report += String.format(java.util.Locale.US, "; window=%.3fs received_fps=%.2f decoded_fps=%.2f texture_fps=%.2f", seconds,
				(received-receiver.reportedReceived)/seconds, (shown-receiver.reportedShown)/seconds, receiver.pacedNew/seconds);
			receiver.reportedAtNs = now;
			receiver.reportedReceived = received;
			receiver.reportedShown = shown;
			receiver.pacedNew = receiver.pacedSkipped = receiver.pacedRepeated = 0;
			return report;
		}
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
	public static long textureFrameTime(int id) {
		VideoReceiver receiver = get(id);
		return receiver == null ? 0 : receiver.frameTimeUs;
	}

	public static String frameTimings(int id) {
		VideoReceiver receiver = get(id);
		if (receiver == null) return "";
		synchronized (receiver) {
			String report = receiver.timings.report() + "; pending_peak=" + receiver.pendingPeak
				+ "; clock_error_ms=" + clockErrorMs + "; wire_version=" + receiver.videoVersion
				+ "; profile=" + (receiver.comparisonTest ? "test" : "original");
			receiver.pendingPeak = 0;
			return report;
		}
	}

	public static long monotonicUsec() { return System.nanoTime() / 1000; }
	public static void recordUplink(int id, long sentUs, long receivedPcUs) {
		VideoReceiver receiver = get(id);
		if (receiver != null && clockKnown && sentUs > 0 && receivedPcUs > 0)
			receiver.timings.add("pose_uplink", (receivedPcUs - sentUs - clockOffsetUs) / 1e3);
	}
	public static double textureAgeMs(int id) {
		VideoReceiver receiver = get(id);
		if (receiver == null || !clockKnown || receiver.frameCapturedUs == 0) return -1;
		return (monotonicUsec() + clockOffsetUs - receiver.frameCapturedUs) / 1e3;
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
		startInternal(id, surface, host, port, false);
	}
	private static void startInternal(int id, Surface surface, String host, int port, boolean startPaced) {
		VideoReceiver previous = receivers.remove(id);
		Thread previousThread = null;
		if (previous != null) {
			previous.halt();
			previousThread = previous.thread;
		}
		VideoReceiver receiver = new VideoReceiver();
		receiver.paced = startPaced;
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
		int oldPose = framePose, oldWidth = bufferWidth, oldHeight = bufferHeight;
		long oldTime = frameTimeUs, oldCapture = frameCapturedUs;
		if (reader == null) {
			return framePointer;
		}
		Image image;
		try {
			boolean sameFrame = paced && comparisonTest && Build.VERSION.SDK_INT >= 33;
			boolean released = sameFrame && releaseNextPending();
			// Release before acquiring. The old order always deferred this image
			// until the next Godot frame, adding ~14 ms even on a perfect link.
			synchronized (imageReady) {
				image = reader.acquireLatestImage();
				if (image == null && released) {
					long start = System.nanoTime();
					try { imageReady.wait(1); } catch (InterruptedException ignored) { Thread.currentThread().interrupt(); }
					image = reader.acquireLatestImage();
					timings.add("image_ready_wait", (System.nanoTime()-start)/1e6);
				}
			}
			if(paced && !sameFrame) releaseNextPending();
			if(image != null && sameFrame) {
				long start = System.nanoTime();
				try (SyncFence fence = image.getFence()) {
					if(fence.isValid() && !fence.await(java.time.Duration.ofMillis(1))) {
						timings.add("image_fence_timeout", 1);image.close();image = null;
					}
				} catch(java.io.IOException e) {
					timings.add("image_fence_error", 1);image.close();image = null;
				}
				timings.add("image_fence_wait", (System.nanoTime()-start)/1e6);
			}
			if(paced) {
				if(image != null) pacedNew++; else pacedRepeated++;
			}
			if (image != null) {
				Integer pose = posesByTime.get(image.getTimestamp() / 1000);
				framePose = pose == null ? 0 : pose;
				frameTimeUs = image.getTimestamp() / 1000;
				posesByTime.headMap(image.getTimestamp() / 1000).clear();
				long[] timing = timingsByTime.get(image.getTimestamp() / 1000);
				frameCapturedUs = timing == null ? 0 : timing[2];
				timingsByTime.headMap(image.getTimestamp() / 1000, true).clear();
				long taken = System.nanoTime();
				if (firstShownNanos != 0 && taken - firstShownNanos > WARMUP_NS) {
					if (lastTakenNs != 0) timings.add("texture_interval", (taken - lastTakenNs) / 1e6);
					if (timing != null) {
						timings.add("decode", (timing[7] - timing[0]) / 1e6);
						timings.add("decoder_input_wait", (timing[0] - timing[1]) / 1e6);
						timings.add("decoded_to_texture", (taken - timing[7]) / 1e6);
						if (clockKnown && timing[2] != 0) {
							timings.add("pc_submit_to_texture", (taken / 1000 + clockOffsetUs - timing[2]) / 1e3);
							if (timing[6] != 0) {
								if (timing[4] > 0) timings.add("pose_pc_to_submit", (timing[2] - timing[4]) / 1e3);
								timings.add("pre_encode", (timing[5] - timing[2]) / 1e3);
								timings.add("encode", (timing[6] - timing[5]) / 1e3);
								timings.add("send_and_network", (timing[1] / 1000 + clockOffsetUs - timing[6]) / 1e3);
							}
						}
					}
				}
				lastTakenNs = taken;
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
			framePose = oldPose; frameTimeUs = oldTime; frameCapturedUs = oldCapture;
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
		} else {
			framePose = oldPose; frameTimeUs = oldTime; frameCapturedUs = oldCapture;
			bufferWidth = oldWidth; bufferHeight = oldHeight;
		}
		return framePointer;
	}

	/** Paced: release one ready buffer, dropping backlog beyond the configured limit. */
	private boolean releaseNextPending() {
		synchronized (pending) {
			if (pendingCodec == null) {
				return false;
			}
			pendingPeak = Math.max(pendingPeak, pending.size());
			try {
				while (pending.size() > pendingMax) {
					pendingCodec.releaseOutputBuffer(pending.poll(), false);
					pacedSkipped++;
				}
				Integer next = pending.poll();
				if (next != null) {
					pendingCodec.releaseOutputBuffer(next, true);
					return true;
				}
			} catch (IllegalStateException e) {
				pending.clear();
			}
		}
		return false;
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
			reader.setOnImageAvailableListener(null, null);
			reader.close();
			reader = null;
		}
		if (imageThread != null) { imageThread.quitSafely(); imageThread = null; }
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
			if (paced) tell(toPc, 3, 5); // request per-frame timestamps; old servers ignore it
			long nextClockPing = 0;

			byte[] magic = new byte[4];
			input.readFully(magic);
			if (magic[0] != 'W' || magic[1] != 'R' || magic[2] != 'K' || magic[3] != 'V') {
				throw new IllegalStateException("это не видео WoRkPlace");
			}
			int version = input.readInt();
			videoVersion = version;
			width = input.readInt();
			height = input.readInt();
			int fps = input.readInt();
			// 3, 4: the PC-drawn eyes (branch pc-render) with a pose id per frame; 4 is HEVC.
			boolean withPose = version == 3 || version == 4 || version == 5;
			String mime = version >= 4 ? MediaFormat.MIMETYPE_VIDEO_HEVC : MediaFormat.MIMETYPE_VIDEO_AVC;
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
					// Texture mode: 4 buffers, 2 held for Godot, 2 for the decoder;
					// paced, 2 more wait their turn.
					synchronized (this) {
						reader = ImageReader.newInstance(width, height, ImageFormat.PRIVATE, paced ? 6 : 4,
								HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE);
						if(paced) {
							imageThread = new HandlerThread("WoRkPlaceImageReady", android.os.Process.THREAD_PRIORITY_DISPLAY);
							imageThread.start();
							reader.setOnImageAvailableListener(unused -> {
								synchronized(imageReady) { imageReady.notifyAll(); }
							}, new Handler(imageThread.getLooper()));
						}
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
			Map<Long, long[]> queuedAt = Collections.synchronizedMap(new HashMap<>());
			if (paced) {
				MediaCodec codec = decoder;
				outputStop = false;
				outputThread = new Thread(() -> {
					MediaCodec.BufferInfo outInfo = new MediaCodec.BufferInfo();
					try {
						while (running && !outputStop) {
							drain(codec, outInfo, queuedAt, 4000);
						}
					} catch (Exception e) {
						status = "ошибка вывода: " + e;
					}
				}, "WoRkPlaceVideoOut");
				outputThread.start();
			}
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
				long poseWrittenUs = version == 5 ? input.readLong() : 0;
				long encodeStartedUs = version == 5 ? input.readLong() : 0;
				long encodedUs = version == 5 ? input.readLong() : 0;
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
				bytesReceived += length + (version == 5 ? 49 : (withPose ? 25 : 21));

				int index;
				while ((index = decoder.dequeueInputBuffer(5000)) < 0) {
					if (!paced) {
						drain(decoder, info, queuedAt, 0);
					}
					if (!running) {
						return;
					}
				}
				ByteBuffer buffer = decoder.getInputBuffer(index);
				buffer.clear();
				buffer.put(frame, 0, length);
				queuedAt.put(time, new long[] { System.nanoTime(), arrived, capturedUs, pose,
					poseWrittenUs, encodeStartedUs, encodedUs, 0 });
				decoder.queueInputBuffer(index, 0, length, time, key ? MediaCodec.BUFFER_FLAG_KEY_FRAME : 0);
				if (!paced) {
					drain(decoder, info, queuedAt, 0);
				}
			}
		} catch (Exception e) {
			if (running) {
				status = "ошибка: " + e;
			}
		} finally {
			synchronized (pending) {
				pending.clear();
				pendingCodec = null;
			}
			if (outputThread != null) {
				outputStop = true;
				try {
					outputThread.join(1000);
				} catch (InterruptedException ignored) {
				}
				outputThread = null;
			}
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

	/** Shows what the decoder has done; waits up to timeoutUs for the first of it. */
	private void drain(MediaCodec decoder, MediaCodec.BufferInfo info, Map<Long, long[]> queuedAt, long timeoutUs) {
		int index;
		while ((index = decoder.dequeueOutputBuffer(info, timeoutUs)) != MediaCodec.INFO_TRY_AGAIN_LATER) {
			timeoutUs = 0;
			if (index < 0) {
				continue; // The output format or buffers changed; nothing to show yet.
			}
			long[] queued = queuedAt.remove(info.presentationTimeUs);
			if (queued != null) {
				long now = System.nanoTime();
				decodeMs = (now - queued[0]) / 1e6;
				queued[7] = now;
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
					timingsByTime.put(info.presentationTimeUs, queued);
					while (timingsByTime.size() > 64) timingsByTime.pollFirstEntry();
					while (posesByTime.size() > 64) {
						posesByTime.pollFirstEntry();
					}
				}
			}
			if (paced) {
				synchronized (pending) {
					pendingCodec = decoder;
					pending.add(index);
				}
			} else {
				decoder.releaseOutputBuffer(index, true);
			}
			framesShown++;
		}
		if (queuedAt.size() > 120) {
			queuedAt.clear(); // Frames the decoder dropped never come out.
		}
	}
}
