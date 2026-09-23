#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <iomanip>
#include <chrono>
#include <map>
#include <vector>
#include <algorithm>
#ifdef _WIN32
#include <windows.h>
#endif
namespace fs = std::filesystem;
using Meta = std::map<std::string, std::string>;
std::string utf(const fs::path& p) { return p.u8string(); }
std::string quote(const std::string& s) {
  std::ostringstream o; o << '"';
  for (unsigned char c : s) {
    if(c=='"' || c=='\\') o << '\\' << c;
    else if(c < 32) o << "\\u" << std::hex << std::setw(4) << std::setfill('0') << int(c);
    else o << c;
  }
  return o.str() + '"';
}
std::string date(std::chrono::system_clock::time_point t = std::chrono::system_clock::now()) {
  auto raw = std::chrono::system_clock::to_time_t(t); std::tm tm{};
#ifdef _WIN32
  gmtime_s(&tm, &raw);
#else
  gmtime_r(&raw, &tm);
#endif
  std::ostringstream o; o << std::put_time(&tm, "%Y-%m-%dT%H:%M:%SZ"); return o.str();
}
std::string modified(const fs::path& p) {
  auto t = fs::last_write_time(p);
  return date(std::chrono::time_point_cast<std::chrono::system_clock::duration>(t - fs::file_time_type::clock::now() + std::chrono::system_clock::now()));
}
void require(bool ok, const std::string& msg) { if(!ok) throw std::runtime_error(msg); }
void nameCheck(const std::string& n) {
  require(!n.empty() && n != "." && n != ".." && n != ".file-hero", "Invalid or reserved name");
  require(n.find_first_of("/\\\r\n\t:<>\"|?*") == std::string::npos && n.back()!='.' && n.back()!=' ', "Invalid portable filename");
  std::string base=n.substr(0,n.find('.')); std::transform(base.begin(),base.end(),base.begin(),[](unsigned char c){return char(std::toupper(c));});
  require(base!="CON" && base!="PRN" && base!="AUX" && base!="NUL" && !(base.size()==4 && (base.substr(0,3)=="COM" || base.substr(0,3)=="LPT") && base[3]>='1' && base[3]<='9'),"Reserved device filename");
}
fs::path resolve(const fs::path& root, const std::string& rel) {
  fs::path r = fs::u8path(rel); require(!r.is_absolute() && !r.has_root_name(), "Absolute path forbidden");
  auto out = root;
  for(const auto& bit : r) {
    if(bit == "." || bit.empty()) continue;
    nameCheck(utf(bit)); out /= bit;
    require(!fs::is_symlink(fs::symlink_status(out)), "Symbolic links are not supported");
  }
  return out;
}
fs::path sidecar(const fs::path& file) {
  auto p = file.parent_path();
  for(const auto& n : {fs::path(".file-hero"), file.filename(), fs::path("file-readme.txt")}) {
    p /= n; require(!fs::is_symlink(fs::symlink_status(p)), "Unsafe metadata symlink");
  }
  return p;
}
Meta readMeta(const fs::path& file) {
  Meta m; std::ifstream in(sidecar(file), std::ios::binary); std::string line;
  while(std::getline(in,line)) {
    if(!line.empty() && line.back()=='\r') line.pop_back();
    auto at=line.find(": "); if(at!=std::string::npos) m[line.substr(0,at)] = line.substr(at+2);
  }
  return m;
}
Meta writeMeta(const fs::path& file, const std::string* desc=nullptr, bool stored=false) {
  auto m=readMeta(file); m["Format"]="file-hero/v1"; m["Name"]=utf(file.filename());
  m["Size-Bytes"]=std::to_string(fs::file_size(file)); m["Modified-UTC"]=modified(file);
  if(m["First-Indexed-UTC"].empty()) m["First-Indexed-UTC"]=date();
  if(m["Last-Stored-UTC"].empty()) m["Last-Stored-UTC"]="unknown";
  if(stored) m["Last-Stored-UTC"]=date();
  if(desc) { require(desc->size()<=8192 && desc->find_first_of("\r\n") == std::string::npos, "Description must be one line, at most 8192 UTF-8 bytes"); m["Description"]=*desc; }
  else if(!m.count("Description")) m["Description"]="";
  auto dest=sidecar(file); fs::create_directories(dest.parent_path()); auto temp=dest; temp += ".tmp";
  require(!fs::exists(temp) && !fs::is_symlink(fs::symlink_status(temp)), "Metadata busy: existing temporary file");
  {std::ofstream o(temp,std::ios::binary); require(bool(o), "Cannot write metadata");
   for(const auto& kv:m) o << kv.first << ": " << kv.second << '\n';
   o.close(); require(bool(o), "Metadata write failed");}
#ifdef _WIN32
  if(!MoveFileExW(temp.c_str(),dest.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)) { fs::remove(temp); throw std::runtime_error("Cannot replace metadata"); }
#else
  fs::rename(temp,dest);
#endif
  return m;
}
std::string metaJson(const Meta& m) {
  std::string out="{"; bool first=true;
  for(const auto& kv:m) { if(!first) out+=","; first=false; out+=quote(kv.first)+":"+quote(kv.second); } return out+"}";
}
void indexTree(const fs::path& p, int& count) {
  for(const auto& e:fs::directory_iterator(p)) {
    if(e.path().filename()==".file-hero" || e.is_symlink()) continue;
    if(e.is_directory()) indexTree(e.path(),count);
    else if(e.is_regular_file()) {writeMeta(e.path()); ++count;}
  }
}
int run(const std::vector<std::string>& a) {
  try {
    require(a.size()>=4, "Usage: core <list|index|import|export|describe|mkdir> <root> <relative-path> [argument]");
    auto root=fs::canonical(fs::u8path(a[2])); require(fs::is_directory(root), "Root is not a directory");
    auto p=resolve(root,a[3]); auto cmd=a[1];
    if(cmd=="list") {
      require(fs::is_directory(p),"Folder not found"); std::vector<fs::directory_entry> entries;
      for(const auto& e:fs::directory_iterator(p)) if(e.path().filename()!=".file-hero" && !e.is_symlink()) entries.push_back(e);
      std::sort(entries.begin(),entries.end(),[](const auto& x,const auto& y){if(x.is_directory()!=y.is_directory()) return x.is_directory(); return x.path()<y.path();});
      auto s=fs::space(root); std::string out="{\"capacity\":"+std::to_string(s.capacity)+",\"available\":"+std::to_string(s.available)+",\"entries\":["; bool first=true;
      for(const auto& e:entries) {
        if(!e.is_directory() && !e.is_regular_file()) continue;
        if(!first) out+=",";
        first=false; bool dir=e.is_directory();
        out+="{\"name\":"+quote(utf(e.path().filename()))+",\"directory\":"+(dir?"true":"false")+",\"size\":"+std::to_string(dir?0:e.file_size())+",\"modified\":"+quote(modified(e.path()))+",\"metadata\":"+metaJson(dir?Meta{}:readMeta(e.path()))+"}";
      } std::cout << out << "]}";
    } else if(cmd=="index") {
      require(fs::is_directory(p),"Folder not found"); int n=0; indexTree(p,n); std::cout << "{\"indexed\":" << n << "}";
    } else if(cmd=="mkdir") {
      require(a.size()==5,"Missing folder name"); nameCheck(a[4]); require(fs::is_directory(p),"Folder not found");
      require(fs::create_directory(resolve(root,utf(fs::relative(p,root)/fs::u8path(a[4])))),"Folder already exists"); std::cout << "{}";
    } else if(cmd=="describe") {
      require(a.size()==5 && fs::is_regular_file(p),"File or description missing"); std::cout << metaJson(writeMeta(p,&a[4]));
    } else if(cmd=="import") {
      require(a.size()==5 && fs::is_directory(p),"Destination or source missing"); auto src=fs::u8path(a[4]);
      require(fs::is_regular_file(src) && !fs::is_symlink(src),"Source must be a regular file"); nameCheck(utf(src.filename()));
      auto dest=resolve(root,utf(fs::relative(p,root)/src.filename()));
      require(!fs::exists(dest),"File already exists; imports never overwrite");
      try {fs::copy_file(src,dest,fs::copy_options::none);} catch(...) {if(fs::exists(dest)) fs::remove(dest); throw;}
      try {writeMeta(dest,nullptr,true);} catch(...) {fs::remove(dest); throw;}
      std::cout << "{}";
    } else if(cmd=="export") {
      require(a.size()==5 && fs::is_regular_file(p),"Source or destination missing"); auto dest=fs::u8path(a[4]);
      require(!fs::exists(dest) && !fs::is_symlink(fs::symlink_status(dest)),"Export target already exists");
      fs::copy_file(p,dest,fs::copy_options::none); std::cout << "{}";
    } else throw std::runtime_error("Unknown command");
    return 0;
  } catch(const std::exception& e) {std::cerr << "{\"error\":" << quote(e.what()) << "}"; return 1;}
}
#ifdef _WIN32
int wmain(int argc,wchar_t** argv) {
  std::vector<std::string> args;
  for(int i=0;i<argc;++i) {int size=WideCharToMultiByte(CP_UTF8,0,argv[i],-1,nullptr,0,nullptr,nullptr); std::string s(size,'\0'); WideCharToMultiByte(CP_UTF8,0,argv[i],-1,s.data(),size,nullptr,nullptr); s.pop_back(); args.push_back(s);}
  return run(args);
}
#else
int main(int argc,char** argv) {return run(std::vector<std::string>(argv,argv+argc));}
#endif
