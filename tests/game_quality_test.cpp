#include "../native/steamvr_driver/game_quality.h"
#include <sstream>
#include <cstdio>

int main() {
	int failures=0;
	auto check=[&](bool ok){if(!ok) failures++;};
	std::istringstream empty("");auto defaults=GameQuality::read(empty);
	check(defaults.bitrate_mbps==90 && defaults.render_percent==140 && defaults.queue_frames==6);
	std::istringstream good("[other]\ngame_bitrate_mbps=110\n[headset]\n game_bitrate_mbps = 80.0\ngame_render_percent=120\ngame_queue_frames=3\n[world]\ngame_queue_frames=1\n");
	auto configured=GameQuality::read(good);
	check(configured.bitrate_mbps==80 && configured.render_percent==120 && configured.queue_frames==3);
	std::istringstream invalid("[headset]\ngame_bitrate_mbps=nan\ngame_render_percent=inf\ngame_queue_frames=2junk\n");
	auto rejected=GameQuality::read(invalid);
	check(rejected.bitrate_mbps==90 && rejected.render_percent==140 && rejected.queue_frames==6);
	std::istringstream limits("[headset]\ngame_bitrate_mbps=99999999999\ngame_render_percent=-1\ngame_queue_frames=99\n");
	auto clamped=GameQuality::read(limits);
	check(clamped.bitrate_mbps==120 && clamped.render_percent==70 && clamped.queue_frames==6);
	std::printf("GameQuality: 4 checks, %d failures\n",failures);return failures?1:0;
}
