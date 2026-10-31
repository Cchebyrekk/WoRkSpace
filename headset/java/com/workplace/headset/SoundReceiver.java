package com.workplace.headset;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioTrack;

import java.io.DataInputStream;
import java.io.InputStream;
import java.net.InetSocketAddress;
import java.net.Socket;

/**
 * The headset side of the PC's sound (31.10.2026): receives the PC's 16-bit PCM
 * over TCP and plays it with AudioTrack. One at a time; it connects again by
 * itself while started (the PC streams only while something plays, and a PC
 * that is not there yet is tried every RETRY_MS). Runs on its own thread;
 * GDScript starts, stops and reads the status through JavaClassWrapper. The
 * stream format is described at SoundBackend in native/src/win_backend.h.
 */
public final class SoundReceiver {
	private static final int CONNECT_TIMEOUT_MS = 3000;
	private static final int RETRY_MS = 1000;
	/** What AudioTrack holds: enough for Wi-Fi's unevenness, little latency. */
	private static final int TRACK_BUFFER_MS = 60;
	/**
	 * Samples waiting in the socket, at most, before the oldest are skipped down
	 * to KEPT_MS: the PC's clock and the headset's differ a little, and a stall
	 * of the network leaves a backlog; neither may build up into a delay.
	 */
	private static final int MAX_WAITING_MS = 150;
	private static final int KEPT_MS = 30;

	private static Thread thread;
	private static volatile boolean running;
	private static volatile Socket socket;
	private static volatile String status = "остановлен";
	private static volatile long bytesReceived;
	private static volatile long bytesSkipped;

	public static synchronized void start(String host, int port) {
		stop();
		running = true;
		bytesReceived = 0;
		bytesSkipped = 0;
		status = "подключаюсь к " + host + ":" + port;
		thread = new Thread(() -> run(host, port), "WoRkPlace sound");
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
		status = "остановлен";
	}

	public static boolean isRunning() {
		return running;
	}

	public static String status() {
		return status;
	}

	public static long bytesReceived() {
		return bytesReceived;
	}

	public static long bytesSkipped() {
		return bytesSkipped;
	}

	private static void closeSocket() {
		Socket current = socket;
		socket = null;
		if (current != null) {
			try {
				current.close();
			} catch (Exception ignored) {
			}
		}
	}

	private static void run(String host, int port) {
		while (running) {
			try {
				receive(host, port);
			} catch (Exception e) {
				if (running) {
					status = "нет звука: " + e.getMessage();
				}
			}
			closeSocket();
			try {
				Thread.sleep(RETRY_MS);
			} catch (InterruptedException e) {
				return;
			}
		}
	}

	private static void receive(String host, int port) throws Exception {
		Socket connection = new Socket();
		connection.setTcpNoDelay(true);
		socket = connection;
		connection.connect(new InetSocketAddress(host, port), CONNECT_TIMEOUT_MS);
		InputStream raw = connection.getInputStream();
		DataInputStream input = new DataInputStream(raw);
		byte[] magic = new byte[4];
		input.readFully(magic);
		if (magic[0] != 'W' || magic[1] != 'R' || magic[2] != 'K' || magic[3] != 'A') {
			throw new Exception("не тот поток");
		}
		input.readInt(); // version
		int rate = input.readInt();
		int channels = input.readInt();
		if (channels != 2 || rate < 8000 || rate > 192000) {
			throw new Exception("формат " + rate + " Гц, каналов " + channels);
		}
		int frameBytes = 4;
		int bytesPerMs = rate * frameBytes / 1000;
		int minimum = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT);
		int size = Math.max(minimum, TRACK_BUFFER_MS * bytesPerMs) / frameBytes * frameBytes;
		AudioTrack track = new AudioTrack.Builder()
				.setAudioAttributes(new AudioAttributes.Builder()
						.setUsage(AudioAttributes.USAGE_MEDIA)
						.setContentType(AudioAttributes.CONTENT_TYPE_UNKNOWN)
						.build())
				.setAudioFormat(new AudioFormat.Builder()
						.setEncoding(AudioFormat.ENCODING_PCM_16BIT)
						.setSampleRate(rate)
						.setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
						.build())
				.setBufferSizeInBytes(size)
				.setTransferMode(AudioTrack.MODE_STREAM)
				.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
				.build();
		try {
			track.play();
			status = "звук " + rate + " Гц с " + host;
			// Whole frames only: a read may end inside one, the rest waits for the next.
			byte[] buffer = new byte[Math.max(4096, 10 * bytesPerMs) / frameBytes * frameBytes];
			int held = 0;
			int maxWaiting = MAX_WAITING_MS * bytesPerMs / frameBytes * frameBytes;
			int kept = KEPT_MS * bytesPerMs / frameBytes * frameBytes;
			while (running) {
				int waiting = raw.available();
				if (held == 0 && waiting > maxWaiting) {
					long skip = (waiting - kept) / frameBytes * frameBytes;
					long done = 0;
					while (done < skip) {
						long step = raw.skip(skip - done);
						if (step <= 0) {
							break;
						}
						done += step;
					}
					// skip() may stop inside a frame: the rest of it is read and dropped.
					int partial = (int) (done % frameBytes);
					if (partial != 0) {
						input.readFully(new byte[frameBytes - partial]);
						done += frameBytes - partial;
					}
					bytesSkipped += done;
				}
				int got = raw.read(buffer, held, buffer.length - held);
				if (got < 0) {
					throw new Exception("ПК закрыл звук");
				}
				bytesReceived += got;
				held += got;
				int whole = held / frameBytes * frameBytes;
				if (whole > 0) {
					track.write(buffer, 0, whole, AudioTrack.WRITE_BLOCKING);
					System.arraycopy(buffer, whole, buffer, 0, held - whole);
					held -= whole;
				}
			}
		} finally {
			track.stop();
			track.release();
		}
	}
}
