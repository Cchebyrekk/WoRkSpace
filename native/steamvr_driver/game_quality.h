#pragma once
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <istream>
#include <string>

// Numeric headset settings only; never writes Godot's configuration.
struct GameQuality {
	int bitrate_mbps=90;
	int render_percent=140;
	int queue_frames=6;
	static std::string trim(const std::string &text) {
		auto begin=text.find_first_not_of(" \t\r\n");
		if(begin==std::string::npos) return {};
		return text.substr(begin,text.find_last_not_of(" \t\r\n")-begin+1);
	}
	static GameQuality read(std::istream &input) {
		GameQuality result;
		bool headset=false;
		std::string line;
		while(std::getline(input,line)) {
			line=trim(line);
			if(!line.empty() && line.front()=='[') {headset=line=="[headset]";continue;}
			if(!headset) continue;
			auto equal=line.find('=');if(equal==std::string::npos) continue;
			auto key=trim(line.substr(0,equal)), text=trim(line.substr(equal+1));
			char *end=nullptr;double value=std::strtod(text.c_str(),&end);
			if(end==text.c_str() || *end || !std::isfinite(value)) continue;
			if(key=="game_bitrate_mbps") result.bitrate_mbps=int(std::clamp(value,30.0,120.0));
			if(key=="game_render_percent") result.render_percent=int(std::clamp(value,70.0,180.0));
			if(key=="game_queue_frames") result.queue_frames=int(std::clamp(value,1.0,6.0));
		}
		return result;
	}
	static GameQuality load() {
		const char *appdata=std::getenv("APPDATA");if(!appdata) return {};
		std::ifstream input(std::filesystem::path(appdata)/"Godot"/"app_userdata"/"WoRkPlace"/"settings.cfg");
		return read(input);
	}
};
