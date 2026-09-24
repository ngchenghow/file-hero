#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <iomanip>
#include <chrono>
#include <map>
#include <set>
#include <vector>
#include <algorithm>
#include <cwctype>
#ifdef _WIN32
#include <windows.h>
#include <winioctl.h>
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
std::string date(std::chrono::system_clock::time_point t = std::chrono::system_clock::now(), const char* format = "%Y-%m-%dT%H:%M:%SZ") {
  auto raw = std::chrono::system_clock::to_time_t(t); std::tm tm{};
#ifdef _WIN32
  gmtime_s(&tm, &raw);
#else
  gmtime_r(&raw, &tm);
#endif
  std::ostringstream o; o << std::put_time(&tm, format); return o.str();
}
std::string modified(const fs::path& p) {
  auto t = fs::last_write_time(p);
  return date(std::chrono::time_point_cast<std::chrono::system_clock::duration>(t - fs::file_time_type::clock::now() + std::chrono::system_clock::now()));
}
std::string lower(std::string s) { std::transform(s.begin(),s.end(),s.begin(),[](unsigned char c){return char(std::tolower(c));}); return s; }
void require(bool ok, const std::string& msg) { if(!ok) throw std::runtime_error(msg); }
bool deviceName(const std::string& n) {
  std::string base=n.substr(0,n.find('.')); std::transform(base.begin(),base.end(),base.begin(),[](unsigned char c){return char(std::toupper(c));});
  return base=="CON" || base=="PRN" || base=="AUX" || base=="NUL" || (base.size()==4 && (base.substr(0,3)=="COM" || base.substr(0,3)=="LPT") && base[3]>='1' && base[3]<='9');
}
void nameCheck(const std::string& n) {
  require(!n.empty() && n != "." && n != ".." && n != ".file-hero", "名称无效或为保留名称");
  require(n.find_first_of("/\\\r\n\t:<>\"|?*") == std::string::npos && n.back()!='.' && n.back()!=' ', "名称含有手机或电脑不支持的字符：/ \\ : < > \" | ? *，且不能以句点或空格结尾");
  require(!deviceName(n), "名称是 Windows 保留设备名（如 CON、NUL、COM1）");
}
// Mirrors Android's portableName: sender names are cleaned up and made unique instead of rejected.
std::string portableName(const std::string& raw, const std::string& fallback, std::set<std::string>& taken) {
  std::string name;
  for(unsigned char c : raw) name += (std::string("/\\:<>\"|?*").find(char(c)) != std::string::npos || c < 32 || c == 127) ? '_' : char(c);
  while(!name.empty() && std::isspace((unsigned char)name.front())) name.erase(0,1);
  while(!name.empty() && (std::isspace((unsigned char)name.back()) || name.back()=='.')) name.pop_back();
  if(name.empty() || name == "." || name == "..") name = fallback;
  auto low=lower(name);
  if(low==".file-hero" || low=="file-readme.txt" || low=="file-readme.txt.tmp" || low=="file-readme.txt.backup") name = "shared-" + name;
  if(deviceName(name)) name = "_" + name;
  auto dot=name.rfind('.'); if(dot==0 || dot==std::string::npos || name.size()-dot > 16) dot=name.size();
  std::string stem, ext=name.substr(dot); size_t points=0;
  for(size_t i=0;i<dot;++i) { if((static_cast<unsigned char>(name[i]) & 0xC0) != 0x80 && ++points > 120) break; stem += name[i]; }
  while(!stem.empty() && (stem.back()=='.' || stem.back()==' ')) stem.pop_back();
  if(stem.empty()) stem = "shared";
  auto candidate=stem+ext; int n=2;
  while(!taken.insert(lower(candidate)).second) candidate=stem+" ("+std::to_string(n++)+")"+ext;
  nameCheck(candidate); return candidate;
}
fs::path resolve(const fs::path& root, const std::string& rel) {
  fs::path r = fs::u8path(rel); require(!r.is_absolute() && !r.has_root_name(), "不允许使用绝对路径");
  auto out = root;
  for(const auto& bit : r) {
    if(bit == "." || bit.empty()) continue;
    nameCheck(utf(bit)); out /= bit;
    require(!fs::is_symlink(fs::symlink_status(out)), "不支持符号链接");
  }
  return out;
}
struct Batch { Meta header; std::map<std::string,Meta> files; };
bool isReadme(const fs::path& file) { return lower(utf(file.filename()))=="file-readme.txt"; }
bool isScratch(const fs::path& file) { auto n=lower(utf(file.filename())); return n=="file-readme.txt.tmp" || n=="file-readme.txt.backup"; }
fs::path manifestPath(const fs::path& folder) {
  auto p=folder/"file-readme.txt"; require(!fs::is_symlink(fs::symlink_status(p)),"说明文件是不安全的符号链接"); return p;
}
Batch readBatch(const fs::path& folder, bool strict=true) {
  Batch batch; auto p=manifestPath(folder); if(!fs::exists(p)) return batch;
  std::ifstream in(p,std::ios::binary); require(bool(in),"无法读取批次说明"); std::string line; Meta* current=&batch.header;
  while(std::getline(in,line)) {
    if(!line.empty() && line.back()=='\r') line.pop_back();
    if(line.rfind("[File: ",0)==0 && line.back()==']') {auto name=line.substr(7,line.size()-8); nameCheck(name); current=&batch.files[name];}
    else {auto at=line.find(": "); if(at!=std::string::npos) (*current)[line.substr(0,at)]=line.substr(at+2);}
  }
  if(batch.header["Format"]!="file-hero/batch-v1") {require(!strict,"已有 file-readme.txt 不是 File Hero 批次说明，不会覆盖"); return {};}
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
  auto dest=manifestPath(folder); auto temp=dest; temp += ".tmp"; auto backup=dest; backup += ".backup";
  // Android leaves .backup behind if it was interrupted; never write over an unrecovered manifest.
  require(!fs::exists(temp) && !fs::is_symlink(fs::symlink_status(temp)) && !fs::exists(backup), "说明文件正忙：存在未完成写入的 file-readme.txt.tmp 或 .backup，请先恢复");
  {std::ofstream o(temp,std::ios::binary); require(bool(o), "无法写入批次说明");
   for(const auto& kv:h) o << kv.first << ": " << kv.second << '\n';
   for(const auto& f:batch.files) {o << "\n[File: " << f.first << "]\n"; for(const auto& kv:f.second) o << kv.first << ": " << kv.second << '\n';}
   o.close(); require(bool(o), "写入批次说明失败");}
#ifdef _WIN32
  if(!MoveFileExW(temp.c_str(),dest.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)) { fs::remove(temp); throw std::runtime_error("无法替换批次说明"); }
#else
  fs::rename(temp,dest);
#endif
}
void oneLine(const std::string& desc) { require(desc.size()<=8192 && desc.find_first_of("\r\n")==std::string::npos,"描述必须为单行，最多 8192 UTF-8 字节"); }
Meta readMeta(const fs::path& file) {
  auto b=readBatch(file.parent_path(),false); auto m=isReadme(file)?b.header:b.files[utf(file.filename())];
  if(!m.empty()) m["Format"]="file-hero/batch-v1";
  return m;
}
Meta writeMeta(const fs::path& file, const std::string* desc=nullptr, bool stored=false) {
  if(desc) oneLine(*desc);
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
bool previewable(const fs::path& p) {
  static const std::set<std::string> ext{".jpg",".jpeg",".png",".gif",".webp",".bmp",".heic",".heif",".mp4",".mov",".m4v",".3gp",".mkv",".webm",".avi",".pdf"};
  return ext.count(lower(utf(p.extension())))>0;
}
// Folder cover: the first previewable file by name, like the Android folder cards.
std::string cover(const fs::path& dir) {
  std::string best; std::error_code ec;
  for(const auto& e:fs::directory_iterator(dir,ec)) if(e.is_regular_file(ec) && !e.is_symlink(ec) && previewable(e.path())) { auto n=utf(e.path().filename()); if(best.empty() || n<best) best=n; }
  return best;
}
void indexTree(const fs::path& p, int& count) {
  auto batch=readBatch(p); auto previous=batch.files; batch.files.clear();
  for(const auto& e:fs::directory_iterator(p)) {
    if(e.path().filename()==".file-hero" || e.is_symlink()) continue;
    if(e.is_directory()) indexTree(e.path(),count);
    else if(e.is_regular_file() && !isReadme(e.path()) && !isScratch(e.path())) {auto name=utf(e.path().filename()); batch.files[name]=record(e.path(),previous[name]); ++count;}
  }
  if(!batch.files.empty() || !batch.header.empty()) writeBatch(p,batch);
}
struct Source { fs::path path; std::string name; uintmax_t size; size_t files; bool directory; };
struct Progress { uintmax_t before=0, total=0; size_t index=0, count=0; unsigned long long last=0; };
// Progress goes to stderr as "@progress <bytes-done> <bytes-total> <files-done> <file-count>"; errors stay the last JSON line.
void report(const Progress& p, uintmax_t done) { std::cerr << "@progress " << p.before+done << ' ' << p.total << ' ' << p.index << ' ' << p.count << std::endl; }
#ifdef _WIN32
DWORD CALLBACK copyProgress(LARGE_INTEGER, LARGE_INTEGER done, LARGE_INTEGER, LARGE_INTEGER, DWORD, DWORD, HANDLE, HANDLE, LPVOID data) {
  auto p=static_cast<Progress*>(data); auto now=GetTickCount64();
  if(now - p->last >= 250) { p->last=now; report(*p,uintmax_t(done.QuadPart)); }
  return PROGRESS_CONTINUE;
}
#endif
void copyFile(const fs::path& src, const fs::path& dst, Progress& p) {
#ifdef _WIN32
  if(!CopyFileExW(src.c_str(),dst.c_str(),copyProgress,&p,nullptr,COPY_FILE_FAIL_IF_EXISTS)) {
    auto err=GetLastError();
    throw std::runtime_error(err==ERROR_FILE_EXISTS?"文件已存在，存入不会覆盖":err==ERROR_DISK_FULL||err==ERROR_HANDLE_DISK_FULL?"SSD 空间不足":"复制失败（错误 "+std::to_string(err)+"），请检查 SSD 是否仍连接");
  }
#else
  fs::copy_file(src,dst,fs::copy_options::none);
#endif
}
bool skipped(const fs::directory_entry& e) {
  std::error_code ec; auto n=lower(utf(e.path().filename()));
  return e.is_symlink(ec) || n=="desktop.ini" || n=="thumbs.db" || n==".ds_store" || n==".file-hero" || isScratch(e.path());
}
void measure(const fs::path& dir, uintmax_t& bytes, size_t& files) {
  for(const auto& e:fs::directory_iterator(dir)) {
    if(skipped(e)) continue;
    if(e.is_directory()) measure(e.path(),bytes,files);
    else if(e.is_regular_file()) { bytes+=e.file_size(); ++files; }
  }
}
bool inside(const fs::path& child, const fs::path& parent) {
  auto c=lower(fs::weakly_canonical(child).generic_u8string()), p=lower(fs::canonical(parent).generic_u8string());
  if(!p.empty() && p.back()=='/') p.pop_back();
  return c==p || c.rfind(p+"/",0)==0;
}
// Files and folders to store; folders are copied with their structure. `destination` guards against copying a folder into itself.
std::vector<Source> sources(const std::vector<std::string>& a, size_t from, const fs::path& destination) {
  std::set<std::string> taken; std::vector<Source> out; auto stamp=date(std::chrono::system_clock::now(),"%Y%m%d-%H%M%S");
  for(size_t i=from;i<a.size();++i) {
    auto src=fs::u8path(a[i]);
    require(!fs::is_symlink(fs::symlink_status(src)) && (fs::is_regular_file(src) || fs::is_directory(src)),"只能存入文件或文件夹："+a[i]);
    auto name=portableName(utf(src.filename()),"shared-"+stamp+"-"+std::to_string(i-from+1),taken);
    if(fs::is_directory(src)) {
      require(!inside(destination,src),"不能把文件夹存入它自己里面："+a[i]);
      Source s{src,name,0,0,true}; measure(src,s.size,s.files); out.push_back(s);
    } else out.push_back({src,name,fs::file_size(src),1,false});
  }
  require(!out.empty(),"没有要存入的文件");
  return out;
}
Progress progressFor(const std::vector<Source>& list) { Progress p; for(const auto& s:list) { p.total+=s.size; p.count+=s.files; } report(p,0); return p; }
void copyOne(const fs::path& src, const fs::path& target, Progress& p) { copyFile(src,target,p); p.before+=fs::file_size(src); ++p.index; report(p,0); }
// Copies a folder tree; every folder gets its own file-readme.txt, like folders browsed on the phone.
// Descriptions from a File Hero manifest already in the source (e.g. a batch from another SSD) are kept.
void copyTree(const fs::path& src, const fs::path& dst, Progress& p, const std::string* description=nullptr) {
  fs::create_directory(dst);
  Batch previous; try { previous=readBatch(src,false); } catch(...) {}
  bool manifest=previous.header.count("Format")>0;
  Batch batch; batch.header["Last-Stored-UTC"]=date();
  if(manifest && previous.header.count("Description")) batch.header["Description"]=previous.header["Description"];
  if(description && !description->empty()) batch.header["Description"]=*description;
  std::vector<fs::directory_entry> entries{fs::directory_iterator(src),fs::directory_iterator()};
  std::sort(entries.begin(),entries.end(),[](const auto& x,const auto& y){return x.path()<y.path();});
  std::set<std::string> taken;
  for(const auto& e:entries) {
    if(skipped(e) || (manifest && isReadme(e.path()))) continue;
    auto original=utf(e.path().filename()); auto name=portableName(original,"shared",taken);
    if(e.is_directory()) copyTree(e.path(),dst/fs::u8path(name),p);
    else if(e.is_regular_file()) {
      auto target=dst/fs::u8path(name); copyOne(e.path(),target,p);
      Meta m; if(previous.files.count(original)) m["Description"]=previous.files[original]["Description"];
      batch.files[name]=record(target,m,true);
    }
  }
  writeBatch(dst,batch);
}
void store(const fs::path& dest, const std::vector<Source>& list, Batch& batch, const std::string& description, std::vector<fs::path>& created, Progress& p) {
  for(const auto& s:list) {
    auto target=dest/fs::u8path(s.name); require(!fs::exists(target),"已有同名项目："+s.name+"。不会覆盖");
    created.push_back(target);
    if(s.directory) { copyTree(s.path,target,p); continue; }
    copyOne(s.path,target,p);
    auto m=record(target,{},true); m["Description"]=description; batch.files[s.name]=m;
  }
}
void removeCreated(const std::vector<fs::path>& created) { std::error_code ec; for(const auto& c:created) fs::remove_all(c,ec); }
#ifdef _WIN32
bool usbBus(wchar_t letter) {
  wchar_t device[]={L'\\',L'\\',L'.',L'\\',letter,L':',0};
  HANDLE h=CreateFileW(device,0,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,0,nullptr);
  if(h==INVALID_HANDLE_VALUE) return false;
  STORAGE_PROPERTY_QUERY query{}; query.PropertyId=StorageDeviceProperty; query.QueryType=PropertyStandardQuery;
  alignas(8) unsigned char buffer[1024]{}; DWORD got=0;
  bool ok=DeviceIoControl(h,IOCTL_STORAGE_QUERY_PROPERTY,&query,sizeof(query),buffer,sizeof(buffer),&got,nullptr) && got>=sizeof(STORAGE_DEVICE_DESCRIPTOR);
  CloseHandle(h);
  return ok && reinterpret_cast<STORAGE_DEVICE_DESCRIPTOR*>(buffer)->BusType==BusTypeUsb;
}
std::string narrow(const wchar_t* w) { int n=WideCharToMultiByte(CP_UTF8,0,w,-1,nullptr,0,nullptr,nullptr); std::string s(n,'\0'); WideCharToMultiByte(CP_UTF8,0,w,-1,s.data(),n,nullptr,nullptr); s.pop_back(); return s; }
#endif
// Candidate SSDs: USB or removable volumes, plus any non-system volume that already has a file-hero folder.
std::string drives() {
  std::string out="["; bool first=true;
#ifdef _WIN32
  wchar_t windows[MAX_PATH]{}; GetWindowsDirectoryW(windows,MAX_PATH); DWORD mask=GetLogicalDrives();
  UINT oldMode=SetErrorMode(SEM_FAILCRITICALERRORS);
  for(int i=0;i<26;++i) {
    if(!(mask & (1u<<i))) continue;
    wchar_t letter=wchar_t(L'A'+i), rootPath[]={letter,L':',L'\\',0};
    UINT type=GetDriveTypeW(rootPath); if(type!=DRIVE_REMOVABLE && type!=DRIVE_FIXED) continue;
    if(std::towupper(windows[0])==letter) continue;
    wchar_t label[MAX_PATH+1]{}, filesystem[MAX_PATH+1]{};
    if(!GetVolumeInformationW(rootPath,label,MAX_PATH+1,nullptr,nullptr,nullptr,filesystem,MAX_PATH+1)) continue;
    std::error_code ec; bool setup=fs::is_directory(fs::path(rootPath)/L"file-hero",ec); bool usb=usbBus(letter);
    if(!setup && !usb && type!=DRIVE_REMOVABLE) continue;
    ULARGE_INTEGER available{}, capacity{}; GetDiskFreeSpaceExW(rootPath,&available,&capacity,nullptr);
    if(!first) out+=",";
    first=false;
    out+="{\"drive\":"+quote(narrow(rootPath))+",\"label\":"+quote(narrow(label))+",\"filesystem\":"+quote(narrow(filesystem))+",\"usb\":"+(usb?"true":"false")+",\"removable\":"+(type==DRIVE_REMOVABLE?"true":"false")+",\"setup\":"+(setup?"true":"false")+",\"capacity\":"+std::to_string(capacity.QuadPart)+",\"available\":"+std::to_string(available.QuadPart)+"}";
  }
  SetErrorMode(oldMode);
#endif
  return out+"]";
}
int run(const std::vector<std::string>& a) {
  try {
    require(a.size()>=2, "Usage: core <drives|setup|list|index|batch|append|import|export|describe|mkdir|delete> <root> <relative-path> [arguments]");
    if(a[1]=="drives") { std::cout << drives(); return 0; }
    if(a[1]=="setup") {
      // All data lives in <SSD>/file-hero, the same folder the Android app uses.
      require(a.size()==3,"缺少 SSD 位置"); auto base=fs::u8path(a[2]); require(fs::is_directory(base),"找不到 SSD 或文件夹");
      auto target=base/"file-hero";
      if(fs::exists(target)) require(fs::is_directory(target) && !fs::is_symlink(fs::symlink_status(target)),"SSD 根目录已有名为 file-hero 的文件，请改名或移走");
      else fs::create_directory(target);
      std::cout << "{\"root\":" << quote(utf(fs::canonical(target))) << "}"; return 0;
    }
    require(a.size()>=4, "缺少参数");
    auto root=fs::canonical(fs::u8path(a[2])); require(fs::is_directory(root), "根目录不是文件夹");
    auto p=resolve(root,a[3]); auto cmd=a[1];
    if(cmd=="list") {
      require(fs::is_directory(p),"找不到文件夹"); std::vector<fs::directory_entry> entries;
      for(const auto& e:fs::directory_iterator(p)) if(e.path().filename()!=".file-hero" && !e.is_symlink()) entries.push_back(e);
      std::sort(entries.begin(),entries.end(),[](const auto& x,const auto& y){if(x.is_directory()!=y.is_directory()) return x.is_directory(); return x.path()<y.path();});
      auto s=fs::space(root); std::string out="{\"capacity\":"+std::to_string(s.capacity)+",\"available\":"+std::to_string(s.available)+",\"entries\":["; bool first=true;
      for(const auto& e:entries) {
        if(!e.is_directory() && !e.is_regular_file()) continue;
        if(!first) out+=",";
        first=false; bool dir=e.is_directory(); Meta meta;
        try { meta=dir?readBatch(e.path(),false).header:readMeta(e.path()); } catch(...) {}
        auto stored=meta.count("Last-Stored-UTC") && meta["Last-Stored-UTC"]!="unknown" ? meta["Last-Stored-UTC"] : modified(e.path());
        out+="{\"name\":"+quote(utf(e.path().filename()))+",\"directory\":"+(dir?"true":"false");
        if(dir) out+=",\"size\":"+(meta.count("Size-Bytes")?meta["Size-Bytes"]:std::string("0"))+",\"fileCount\":"+(meta.count("File-Count")?meta["File-Count"]:std::string("null"))+",\"modified\":"+quote(stored)+",\"cover\":"+quote(cover(e.path()));
        else out+=",\"size\":"+std::to_string(e.file_size())+",\"modified\":"+quote(modified(e.path()));
        out+=",\"metadata\":"+metaJson(meta)+"}";
      } std::cout << out << "]}";
    } else if(cmd=="index") {
      require(fs::is_directory(p),"找不到文件夹"); int n=0; indexTree(p,n); std::cout << "{\"indexed\":" << n << "}";
    } else if(cmd=="mkdir") {
      require(a.size()==5,"缺少文件夹名称"); nameCheck(a[4]); require(fs::is_directory(p),"找不到文件夹");
      require(fs::create_directory(resolve(root,utf(fs::relative(p,root)/fs::u8path(a[4])))),"文件夹已存在"); std::cout << "{}";
    } else if(cmd=="describe") {
      require(a.size()==5 && fs::is_regular_file(p),"缺少文件或描述"); std::cout << metaJson(writeMeta(p,&a[4]));
    } else if(cmd=="batch") {
      // batch <root> <parent> <new-folder> <description> <files...>
      require(a.size()>=7 && fs::is_directory(p),"需要文件夹名称、描述和文件"); nameCheck(a[4]); oneLine(a[5]);
      auto dest=resolve(root,utf(fs::relative(p,root)/fs::u8path(a[4]))); size_t count=0;
      require(!fs::exists(dest),"此文件夹已存在，请选择「已有文件夹」或更换名称");
      auto list=sources(a,6,dest);
      require(fs::create_directory(dest),"无法在 SSD 创建文件夹");
      try {
        auto progress=progressFor(list); count=progress.count;
        // A single shared folder becomes the new folder itself instead of being nested inside it.
        if(list.size()==1 && list[0].directory) copyTree(list[0].path,dest,progress,&a[5]);
        else {
          Batch batch; batch.header["Description"]=a[5]; batch.header["Last-Stored-UTC"]=date();
          std::vector<fs::path> created; store(dest,list,batch,"",created,progress);
          writeBatch(dest,batch);
        }
        std::cout << "{\"imported\":" << count << ",\"batch\":" << quote(a[4]) << ",\"path\":" << quote(utf(fs::relative(dest,root).generic_u8string())) << "}";
      } catch(...) {std::error_code ec; fs::remove_all(dest,ec); throw;}
    } else if(cmd=="append") {
      // append <root> <folder> <description-for-new-files> <files...>; the folder keeps its own description.
      require(a.size()>=6 && fs::is_directory(p),"需要目标文件夹和文件"); oneLine(a[4]);
      auto list=sources(a,5,p); auto batch=readBatch(p);
      for(const auto& s:list) require(!fs::exists(p/fs::u8path(s.name)),"已有同名项目："+s.name+"。不会覆盖，请选择其他文件夹或新建文件夹");
      auto previous=batch.files; batch.files.clear();
      for(const auto& e:fs::directory_iterator(p)) {
        if(!e.is_regular_file() || e.is_symlink() || isReadme(e.path()) || isScratch(e.path())) continue;
        auto name=utf(e.path().filename()); try { nameCheck(name); } catch(...) { continue; }
        batch.files[name]=record(e.path(),previous[name]);
      }
      batch.header["Last-Stored-UTC"]=date();
      std::vector<fs::path> created; size_t count=0;
      try { auto progress=progressFor(list); count=progress.count; store(p,list,batch,a[4],created,progress); writeBatch(p,batch); } catch(...) { removeCreated(created); throw; }
      std::cout << "{\"imported\":" << count << ",\"batch\":" << quote(p==root?std::string("file-hero"):utf(p.filename())) << ",\"path\":" << quote(a[3]) << "}";
    } else if(cmd=="delete") {
      require(p!=root && !a[3].empty(),"不能删除 file-hero 根目录");
      if(fs::is_directory(p)) { fs::remove_all(p); std::cout << "{\"deleted\":true,\"warning\":\"\"}"; return 0; }
      require(fs::is_regular_file(p),"找不到文件");
      auto parent=p.parent_path(); Batch batch; bool update=false;
      if(!isReadme(p)) try { update=fs::exists(manifestPath(parent)); batch=readBatch(parent); } catch(...) { update=false; }
      fs::remove(p); std::string warning;
      if(update) { batch.files.erase(utf(p.filename())); try { writeBatch(parent,batch); } catch(const std::exception& e) { warning=std::string("文件已删除，但说明未完整更新：")+e.what(); } }
      std::cout << "{\"deleted\":true,\"warning\":" << quote(warning) << "}";
    } else if(cmd=="import") {
      require(a.size()==5 && fs::is_directory(p),"缺少目标或来源"); auto src=fs::u8path(a[4]);
      require(fs::is_regular_file(src) && !fs::is_symlink(src),"只能存入普通文件"); nameCheck(utf(src.filename()));
      require(!isReadme(src),"file-readme.txt 是批次说明的保留名称");
      auto dest=resolve(root,utf(fs::relative(p,root)/src.filename()));
      require(!fs::exists(dest),"文件已存在，存入不会覆盖");
      try {fs::copy_file(src,dest,fs::copy_options::none);} catch(...) {if(fs::exists(dest)) fs::remove(dest); throw;}
      try {writeMeta(dest,nullptr,true);} catch(...) {fs::remove(dest); throw;}
      std::cout << "{}";
    } else if(cmd=="export" && fs::is_directory(p)) {
      // export <root> <folder> <destination-parent>: copies the folder (subfolders included) into a new folder there.
      require(a.size()==5 && p!=root,"缺少来源或目标"); auto parent=fs::u8path(a[4]);
      require(fs::is_directory(parent),"找不到导出位置");
      // List everything first, so a destination inside the source folder is never copied into itself.
      std::vector<fs::path> dirs, files;
      for(auto it=fs::recursive_directory_iterator(p); it!=fs::recursive_directory_iterator(); ++it) {
        auto name=it->path().filename();
        if(it->is_symlink() || name==".file-hero" || isScratch(it->path())) { if(it->is_directory()) it.disable_recursion_pending(); continue; }
        if(it->is_directory()) dirs.push_back(fs::relative(it->path(),p)); else if(it->is_regular_file()) files.push_back(fs::relative(it->path(),p));
      }
      auto base=utf(p.filename()); auto dest=parent/p.filename();
      for(int n=2; fs::exists(fs::symlink_status(dest)); ++n) dest=parent/fs::u8path(base+" ("+std::to_string(n)+")");
      fs::create_directory(dest);
      try {
        for(const auto& d:dirs) fs::create_directory(dest/d);
        for(const auto& f:files) fs::copy_file(p/f,dest/f,fs::copy_options::none);
      } catch(...) {std::error_code ec; fs::remove_all(dest,ec); throw;}
      std::cout << "{\"name\":" << quote(utf(dest.filename())) << ",\"files\":" << files.size() << ",\"path\":" << quote(utf(dest)) << "}";
    } else if(cmd=="export") {
      require(a.size()==5 && fs::is_regular_file(p),"缺少来源或目标"); auto dest=fs::u8path(a[4]);
      require(!fs::exists(dest) && !fs::is_symlink(fs::symlink_status(dest)),"导出目标已存在，不会覆盖");
      fs::copy_file(p,dest,fs::copy_options::none); std::cout << "{}";
    } else throw std::runtime_error("未知命令");
    return 0;
  } catch(const std::exception& e) {std::cerr << "{\"error\":" << quote(e.what()) << "}" << std::endl; return 1;}
}
#ifdef _WIN32
int wmain(int argc,wchar_t** argv) {
  std::vector<std::string> args;
  for(int i=0;i<argc;++i) args.push_back(narrow(argv[i]));
  return run(args);
}
#else
int main(int argc,char** argv) {return run(std::vector<std::string>(argv,argv+argc));}
#endif
