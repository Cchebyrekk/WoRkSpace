package com.workplace.headset;

import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

/** Bounded per-stage latency samples. All values are milliseconds. */
public final class FrameTimings {
	private static final int CAPACITY = 4096;
	private static final class Samples {
		final double[] values = new double[CAPACITY];
		int count;
		long total;
		double max;
		void add(double value) {
			values[(int)(total++ % CAPACITY)] = value;
			count = Math.min(count + 1, CAPACITY);
			max = Math.max(max, value);
		}
	}
	private final Map<String, Samples> stages = new LinkedHashMap<>();
	private long rejected;
	public synchronized void add(String name, double value) {
		if (!Double.isFinite(value) || value < 0) { rejected++; return; }
		stages.computeIfAbsent(name, key -> new Samples()).add(value);
	}
	public static double percentile(double[] sorted, double fraction) {
		if (sorted.length == 0) return 0;
		return sorted[Math.max(0, Math.min(sorted.length - 1, (int)Math.ceil(sorted.length * fraction) - 1))];
	}
	public synchronized String report() {
		StringBuilder result = new StringBuilder("ms p50/p95/p99/max");
		for (Map.Entry<String, Samples> entry : stages.entrySet()) {
			Samples sample = entry.getValue();
			double[] sorted = Arrays.copyOf(sample.values, sample.count);
			Arrays.sort(sorted);
			result.append(String.format(Locale.US, "; %s n=%d %.2f/%.2f/%.2f/%.2f", entry.getKey(), sample.total,
				percentile(sorted, .5), percentile(sorted, .95), percentile(sorted, .99), sample.max));
		}
		result.append("; invalid=").append(rejected);
		stages.clear(); rejected = 0;
		return result.toString();
	}
}
