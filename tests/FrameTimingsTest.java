package com.workplace.headset;

public final class FrameTimingsTest {
	private static void check(boolean ok) { if (!ok) throw new AssertionError(); }
	public static void main(String[] args) {
		check(FrameTimings.percentile(new double[]{}, .95) == 0);
		check(FrameTimings.percentile(new double[]{3}, .99) == 3);
		check(FrameTimings.percentile(new double[]{1, 9}, .5) == 1);
		check(FrameTimings.percentile(new double[]{1, 9}, .95) == 9);
		FrameTimings timings = new FrameTimings();
		for (int i = 1; i <= 100; i++) timings.add("encode", i);
		timings.add("encode", Double.NaN); timings.add("encode", -1);
		String report = timings.report();
		check(report.contains("encode n=100 50.00/95.00/99.00/100.00"));
		check(report.contains("invalid=2"));
		check(!timings.report().contains("encode"));
		for (int i = 1; i <= 5000; i++) timings.add("bounded", i);
		check(timings.report().contains("bounded n=5000 2952.00/4796.00/4960.00/5000.00"));
		System.out.println("FrameTimings: 9 checks passed");
	}
}
