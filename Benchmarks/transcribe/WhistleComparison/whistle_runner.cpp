// Minimal headless runner over the publisher's static C API. No Python SDK.
#include "needle.h"
#include <chrono>
#include <fstream>
#include <iostream>
#include <iterator>
#include <sstream>
#include <string>
#include <vector>
#include <algorithm>
#include <stdexcept>
using Clock = std::chrono::steady_clock;
double elapsed(Clock::time_point t) { return std::chrono::duration<double>(Clock::now()-t).count(); }
std::vector<char> read(const std::string& p) {
    std::ifstream f(p, std::ios::binary);
    if(!f) throw std::runtime_error("Cannot open " + p);
    return {std::istreambuf_iterator<char>(f), {}};
}
std::vector<float> audio(const std::string& p) {
    auto b=read(p);
    if(b.size()%4) throw std::runtime_error("Invalid float PCM");
    std::vector<float> v(b.size()/4);
    std::copy(b.begin(),b.end(),reinterpret_cast<char*>(v.data()));
    return v;
}
struct Item { std::string id,path,lang,hints; };
int main(int argc,char** argv) {
    if(argc!=7) { std::cerr << "model jobs.tsv output.jsonl warmup.f32 repeats mode(batch|stream)\n"; return 2; }
    try {
        auto model=read(argv[1]);
        std::ofstream out(argv[3]);
        auto start=Clock::now();
        if(needle_load(reinterpret_cast<const unsigned char*>(model.data()),model.size())<0) throw std::runtime_error(needle_last_error());
        out << "{\"type\":\"load\",\"engine\":\"whistle\",\"seconds\":" << elapsed(start) << "}\n";
        std::vector<char> buffer(1<<20);
        auto warm=audio(argv[4]);
        start=Clock::now();
        if(needle_transcribe(warm.data(),int(warm.size()),nullptr,nullptr,1,buffer.data(),int(buffer.size()))<0) throw std::runtime_error(needle_last_error());
        out << "{\"type\":\"warmup\",\"engine\":\"whistle\",\"seconds\":" << elapsed(start) << "}\n";
        std::ifstream manifest(argv[2]);
        std::vector<Item> items;
        for(std::string line;std::getline(manifest,line);) {
            std::istringstream s(line); Item i;
            std::getline(s,i.id,'\t'); std::getline(s,i.path,'\t'); std::getline(s,i.lang,'\t'); std::getline(s,i.hints);
            std::replace(i.hints.begin(),i.hints.end(),'|','\n'); items.push_back(i);
        }
        bool stream=std::string(argv[6])=="stream";
        for(int rep=0;rep<std::stoi(argv[5]);++rep) {
            auto order=items;
            if(rep%2) std::reverse(order.begin(),order.end());
            for(auto& i:order) {
                auto pcm=audio(i.path);
                const char* lang=i.lang.empty()?nullptr:i.lang.c_str();
                const char* hints=i.hints.empty()?nullptr:i.hints.c_str();
                start=Clock::now();
                if(!stream) {
                    int n=needle_transcribe(pcm.data(),int(pcm.size()),lang,hints,1,buffer.data(),int(buffer.size()));
                    double secs=elapsed(start);
                    if(n<0) throw std::runtime_error(needle_last_error());
                    out << "{\"id\":\"" << i.id << "\",\"engine\":\"whistle\",\"repeat\":" << rep
                        << ",\"audioSeconds\":" << pcm.size()/16000.0 << ",\"seconds\":" << secs << ",\"result\":" << buffer.data() << "}\n";
                    std::cerr << "whistle " << rep << " " << i.id << " " << secs << "s\n";
                } else {
                    for(size_t pos=0;pos<pcm.size();pos+=16000) {
                        size_t len=std::min(size_t(16000),pcm.size()-pos);
                        auto step=Clock::now();
                        if(needle_stream_transcribe_process(pcm.data()+pos,int(len),lang,hints,buffer.data(),int(buffer.size()))<0) throw std::runtime_error(needle_last_error());
                        out << "{\"id\":\"" << i.id << "\",\"repeat\":" << rep << ",\"received\":" << (pos+len)/16000.0
                            << ",\"seconds\":" << elapsed(step) << ",\"result\":" << buffer.data() << "}\n";
                    }
                    if(needle_stream_transcribe_stop(buffer.data(),int(buffer.size()))<0) throw std::runtime_error(needle_last_error());
                    out << "{\"id\":\"" << i.id << "\",\"repeat\":" << rep << ",\"final\":true,\"totalSeconds\":" << elapsed(start) << ",\"result\":" << buffer.data() << "}\n";
                }
                out.flush();
            }
        }
    } catch(const std::exception& e) { std::cerr << e.what() << "\n"; return 1; }
}
