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
struct Batch { Meta header; std::map<std::string,Meta> files; };
bool isReadme(const fs::path& file) { auto n=utf(file.filename()); std::transform(n.begin(),n.end(),n.begin(),[](unsigned char c){return char(std::tolower(c));}); return n=="file-readme.txt"; }
fs::path manifestPath(const fs::path& folder) {
  auto p=folder/"file-readme.txt"; require(!fs::is_symlink(fs::symlink_status(p)),"Unsafe manifest symlink"); return p;
}
Batch readBatch(const fs::path& folder, bool strict=true) {
  Batch batch; auto p=manifestPath(folder); if(!fs::exists(p)) return batch;
  std::ifstream in(p,std::ios::binary); require(bool(in),"Cannot read batch manifest"); std::string line; Meta* current=&batch.header;
  while(std::getline(in,line)) {
    if(!line.empty() && line.back()=='\r') line.pop_back();
    if(line.rfind("[File: ",0)==0 && line.back()==']') {auto name=line.substr(7,line.size()-8); nameCheck(name); current=&batch.files[name];}
    else {auto at=line.find(": "); if(at!=std::string::npos) (*current)[line.substr(0,at)]=line.substr(at+2);}
  }
  if(batch.header["Format"]!="file-hero/batch-v1") {require(!strict,"Existing file-readme.txt is not a File Hero manifest; it will not be overwritten"); return {};}
  return batch;
}
Meta record(const fs::path& file, Meta m={}, bool stored=false) {
  m["Name"]=utf(file.filename());
  m["Size-Bytes"]=std::to_string(fs::file_size(file)); m["Modified-UTC"]=modified(file);
  if(m["First-Indexed-UTC"].empty()) m["First-Indexed-UTC"]=date();
  if(m["Last-Stored-UTC"].empty()) m["Last-Stored-UTC"]="unknown";
  if(stored) m["Last-Stored-UTC"]=date();
  if(!m.count("Description")) m["Description"]="";
  return m;
}
void writeBatch(const fs::path& folder, Batch& batch) {
  auto& h=batch.header; h["Format"]="file-hero/batch-v1"; h["Batch"]=utf(folder.filename());
  if(!h.count("Description")) h["Description"]="";
  if(!h.count("Created-UTC")) h["Created-UTC"]=date();
  if(!h.count("Last-Stored-UTC")) h["Last-Stored-UTC"]="unknown";
  uintmax_t total=0; for(const auto& kv:batch.files) total+=std::stoull(kv.second.at("Size-Bytes"));
  h["File-Count"]=std::to_string(batch.files.size()); h["Size-Bytes"]=std::to_string(total);
  auto dest=manifestPath(folder); auto temp=dest; temp += ".tmp";
  require(!fs::exists(temp) && !fs::is_symlink(fs::symlink_status(temp)), "Metadata busy: existing temporary file");
  {std::ofstream o(temp,std::ios::binary); require(bool(o), "Cannot write metadata");
   for(const auto& kv:h) o << kv.first << ": " << kv.second << '\n';
   for(const auto& f:batch.files) {o << "\n[File: " << f.first << "]\n"; for(const auto& kv:f.second) o << kv.first << ": " << kv.second << '\n';}
   o.close(); require(bool(o), "Metadata write failed");}
#ifdef _WIN32
  if(!MoveFileExW(temp.c_str(),dest.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)) { fs::remove(temp); throw std::runtime_error("Cannot replace metadata"); }
#else
  fs::rename(temp,dest);
#endif
}
Meta readMeta(const fs::path& file) {
  auto b=readBatch(file.parent_path(),false); auto m=isReadme(file)?b.header:b.files[utf(file.filename())];
  if(!m.empty()) m["Format"]="file-hero/batch-v1";
  return m;
}
Meta writeMeta(const fs::path& file, const std::string* desc=nullptr, bool stored=false) {
  if(desc) require(desc->size()<=8192 && desc->find_first_of("\r\n")==std::string::npos,"Description must be one line, at most 8192 UTF-8 bytes");
  auto b=readBatch(file.parent_path());
  auto& m=isReadme(file)?b.header:b.files[utf(file.filename())];
  if(!isReadme(file)) m=record(file,m,stored);
  if(desc) m["Description"]=*desc;
  if(stored) b.header["Last-Stored-UTC"]=date();
  writeBatch(file.parent_path(),b); auto result=m; result["Format"]="file-hero/batch-v1"; return result;
}
std::string metaJson(const Meta& m) {
  std::string out="{"; bool first=true;
  for(const auto& kv:m) { if(!first) out+=","; first=false; out+=quote(kv.first)+":"+quote(kv.second); } return out+"}";
}
void indexTree(const fs::path& p, int& count) {
  auto batch=readBatch(p); auto previous=batch.files; batch.files.clear();
  for(const auto& e:fs::directory_iterator(p)) {
    if(e.path().filename()==".file-hero" || e.is_symlink()) continue;
    if(e.is_directory()) indexTree(e.path(),count);
    else if(e.is_regular_file() && !isReadme(e.path()) && e.path().filename()!="file-readme.txt.tmp") {auto name=utf(e.path().filename()); batch.files[name]=record(e.path(),previous[name]); ++count;}
  }
  if(!batch.files.empty() || !batch.header.empty()) writeBatch(p,batch);
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
    } else if(cmd=="batch") {
      require(a.size()>=7 && fs::is_directory(p),"Batch name, description and files required"); nameCheck(a[4]);
      require(a[5].size()<=8192 && a[5].find_first_of("\r\n")==std::string::npos,"Batch description must be a single line, at most 8192 bytes");
      auto dest=resolve(root,utf(fs::relative(p,root)/fs::u8path(a[4])));
      require(!fs::exists(dest),"Batch folder already exists");
      std::vector<fs::path> sources; std::vector<std::string> names;
      for(size_t i=6;i<a.size();++i) {
        auto src=fs::u8path(a[i]); auto name=utf(src.filename()); nameCheck(name);
        auto lower=name; std::transform(lower.begin(),lower.end(),lower.begin(),[](unsigned char c){return char(std::tolower(c));});
        require(lower!="file-readme.txt","file-readme.txt is reserved for the batch description");
        require(std::find(names.begin(),names.end(),lower)==names.end(),"Duplicate filenames in batch"); names.push_back(lower);
        require(fs::is_regular_file(src) && !fs::is_symlink(src),"Source must be a regular file"); sources.push_back(src);
      }
      require(fs::create_directory(dest),"Cannot create batch folder");
      try {
        Batch batch; batch.header["Description"]=a[5]; batch.header["Last-Stored-UTC"]=date();
        for(const auto& src:sources) {auto target=dest/src.filename(); fs::copy_file(src,target,fs::copy_options::none); batch.files[utf(src.filename())]=record(target,{},true);}
        writeBatch(dest,batch);
        std::cout << "{\"imported\":" << sources.size() << ",\"batch\":" << quote(a[4]) << "}";
      } catch(...) {fs::remove_all(dest); throw;}
    } else if(cmd=="import") {
      require(a.size()==5 && fs::is_directory(p),"Destination or source missing"); auto src=fs::u8path(a[4]);
      require(fs::is_regular_file(src) && !fs::is_symlink(src),"Source must be a regular file"); nameCheck(utf(src.filename()));
      require(!isReadme(src),"file-readme.txt is reserved for batch metadata");
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
