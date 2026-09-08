#include "rdp_clipboard_content.h"
#include "rdp_clipboard_codec.h"
#include <algorithm>
#include <cstring>
#include <cstdio>
#include <limits>

namespace RdpClipboardContentCodec {
namespace {
uint32_t le(const uint8_t* p) { return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24; }
uint32_t be(const uint8_t* p) { return uint32_t(p[3]) | uint32_t(p[2]) << 8 | uint32_t(p[1]) << 16 | uint32_t(p[0]) << 24; }
void put(std::vector<uint8_t>& b, size_t p, uint32_t v) { for (int i = 0; i < 4; ++i) b[p+i] = uint8_t(v >> (8*i)); }
bool dimensions(uint32_t w, uint32_t h) { return w && h && w <= kMaxDimension && h <= kMaxDimension && uint64_t(w)*h <= kMaxPixels; }
bool utf8(const std::string& value, size_t limit) {
    if (value.size() > limit || value.find('\0') != std::string::npos) return false;
    // Validate UTF-8 directly; rich text has a separate, larger budget.
    for (size_t i = 0; i < value.size();) {
        const auto c = uint8_t(value[i++]); uint32_t cp = c; size_t extra = 0; uint32_t minimum = 0;
        if (c < 0x80) continue;
        if (c >= 0xc2 && c <= 0xdf) { extra = 1; cp &= 31; minimum = 0x80; }
        else if (c >= 0xe0 && c <= 0xef) { extra = 2; cp &= 15; minimum = 0x800; }
        else if (c >= 0xf0 && c <= 0xf4) { extra = 3; cp &= 7; minimum = 0x10000; }
        else return false;
        if (extra > value.size()-i) return false;
        while (extra--) { const auto d = uint8_t(value[i++]); if ((d&0xc0)!=0x80) return false; cp=(cp<<6)|(d&63); }
        if (cp < minimum || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) return false;
    }
    return true;
}
uint32_t crc32(const uint8_t* p, size_t n) {
    uint32_t crc = ~0u;
    while (n--) { crc ^= *p++; for (int i=0;i<8;++i) crc=(crc>>1)^((0u-(crc&1u))&0xedb88320u); }
    return ~crc;
}
}
bool validatePng(const uint8_t* data, size_t size, uint32_t& width, uint32_t& height) {
    width = height = 0;
    const uint8_t signature[] = {137,80,78,71,13,10,26,10};
    if (!data || size < 57 || size > kMaxPngBytes || std::memcmp(data,signature,8)) return false;
    bool ihdr=false, idat=false, endedIdat=false, palette=false, iend=false;
    size_t at=8;
    while (at < size) {
        if (size-at < 12) return false;
        const size_t n=be(data+at);
        if (n > size-at-12) return false;
        const uint8_t* type=data+at+4; const uint8_t* body=data+at+8;
        if (crc32(type,n+4) != be(body+n)) return false;
        for (int i=0;i<4;++i) if (!((type[i]>='A'&&type[i]<='Z')||(type[i]>='a'&&type[i]<='z'))) return false;
        if (std::memcmp(type,"IHDR",4)==0) {
            if (ihdr || at != 8 || n != 13) return false;
            width=be(body); height=be(body+4);
            if (!dimensions(width,height) || body[10] || body[11] || body[12]>1) return false;
            const auto depth=body[8], color=body[9];
            if (!((color==0&&(depth==1||depth==2||depth==4||depth==8||depth==16)) ||
                  (color==2&&(depth==8||depth==16)) || (color==3&&(depth==1||depth==2||depth==4||depth==8)) ||
                  ((color==4||color==6)&&(depth==8||depth==16)))) return false;
            ihdr=true;
        } else if (!ihdr) return false;
        else if (std::memcmp(type,"PLTE",4)==0) { if (palette||idat||!n||n>768||n%3) return false; palette=true; }
        else if (std::memcmp(type,"IDAT",4)==0) { if (endedIdat || (data[25]==3&&!palette)) return false; idat=true; }
        else if (std::memcmp(type,"IEND",4)==0) { if (n || !idat || at+12!=size) return false; iend=true; }
        else { if (!(type[0]&0x20)) return false; if (idat) endedIdat=true; }
        at += n+12;
    }
    return ihdr && idat && iend;
}
bool encodeDibV5(const std::vector<uint8_t>& rgba, uint32_t width, uint32_t height, std::vector<uint8_t>& result) {
    result.clear();
    if (!dimensions(width,height) || rgba.size()!=uint64_t(width)*height*4) return false;
    result.assign(124+rgba.size(),0); put(result,0,124); put(result,4,width); put(result,8,0u-height);
    result[12]=1; result[14]=32; put(result,16,3); put(result,20,rgba.size());
    put(result,40,0x00ff0000); put(result,44,0x0000ff00); put(result,48,0x000000ff); put(result,52,0xff000000);
    put(result,56,0x73524742); put(result,108,4);
    for (size_t i=0;i<rgba.size();i+=4) { result[124+i]=rgba[i+2]; result[125+i]=rgba[i+1]; result[126+i]=rgba[i]; result[127+i]=rgba[i+3]; }
    return true;
}
bool decodeDibV5(const uint8_t* data, size_t size, RdpClipboardContent& result) {
    if (!data||size<124||size>124+kMaxPixels*4||le(data)!=124) return false;
    const uint32_t w=le(data+4), rawH=le(data+8); const bool top=rawH&0x80000000u; const uint32_t h=top?0u-rawH:rawH;
    if (!dimensions(w,h)||data[12]!=1||data[13]||data[14]!=32||data[15]||le(data+16)!=3||
        le(data+32)||le(data+36)||le(data+40)!=0x00ff0000||le(data+44)!=0x0000ff00||le(data+48)!=0xff||
        le(data+52)!=0xff000000||le(data+56)!=0x73524742||le(data+112)||le(data+116)||le(data+120)) return false;
    for (size_t i=60;i<108;++i) if (data[i]) return false; // no embedded calibrated color/gamma
    const size_t bytes=size_t(w)*h*4;
    if ((le(data+20)!=0&&le(data+20)!=bytes)||size!=124+bytes) return false;
    std::vector<uint8_t> rgba(bytes);
    for (uint32_t y=0;y<h;++y) for (uint32_t x=0;x<w;++x) {
        const size_t dst=(size_t(y)*w+x)*4, src=124+(size_t(top?y:h-1-y)*w+x)*4;
        rgba[dst]=data[src+2]; rgba[dst+1]=data[src+1]; rgba[dst+2]=data[src]; rgba[dst+3]=data[src+3];
    }
    result.rgbaStraight=std::move(rgba); result.width=w; result.height=h; return true;
}
bool encodeHtml(const std::string& fragment, std::vector<uint8_t>& result) {
    result.clear(); if (!utf8(fragment,kMaxRichBytes)) return false;
    const std::string before="<html><body><!--StartFragment-->", after="<!--EndFragment--></body></html>";
    const char* pattern="Version:1.0\r\nStartHTML:%010zu\r\nEndHTML:%010zu\r\nStartFragment:%010zu\r\nEndFragment:%010zu\r\n";
    char header[256]; const int length=std::snprintf(header,sizeof(header),pattern,size_t(0),size_t(0),size_t(0),size_t(0));
    const size_t start=static_cast<size_t>(length), end=start+before.size()+fragment.size()+after.size();
    if (end+1>kMaxRichBytes) return false;
    std::snprintf(header,sizeof(header),pattern,start,end,start+before.size(),start+before.size()+fragment.size());
    const std::string full=std::string(header)+before+fragment+after;
    result.assign(full.begin(),full.end()); result.push_back(0); return true;
}
bool decodeHtml(const uint8_t* data, size_t size, std::string& result) {
    result.clear(); if (!data||!size||size>kMaxRichBytes) return false;
    if (data[size-1]==0) --size;
    std::string value(reinterpret_cast<const char*>(data),size);
    if (!utf8(value,kMaxRichBytes) || value.rfind("Version:",0)!=0) return false;
    size_t start=0,end=0,fs=0,fe=0; bool s=false,e=false,f=false,g=false; size_t at=0;
    while (at<size && at<4096) {
        const size_t nl=value.find('\n',at); if (nl==std::string::npos) return false;
        std::string line=value.substr(at,nl-at); if (!line.empty()&&line.back()=='\r') line.pop_back();
        auto field=[&](const char* key,size_t& number,bool& found) {
            const size_t len=std::strlen(key); if (line.compare(0,len,key)!=0) return true;
            if (found||line.size()==len) return false; found=true; number=0;
            for (size_t p=len;p<line.size();++p) { const char c=line[p]; if (c<'0'||c>'9'||number>(size-size_t(c-'0'))/10) return false; number=number*10+size_t(c-'0'); }
            return number<=size;
        };
        if (!field("StartHTML:",start,s)||!field("EndHTML:",end,e)||!field("StartFragment:",fs,f)||!field("EndFragment:",fe,g)) return false;
        at=nl+1; if (s&&e&&f&&g) break;
    }
    if (!(s&&e&&f&&g)||start<at||start>fs||fs>fe||fe>end||end>size) return false;
    result=value.substr(fs,fe-fs); return utf8(result,kMaxRichBytes);
}
bool validateRtf(const uint8_t* data,size_t size) {
    return data&&size>=7&&size<=kMaxRichBytes&&std::memcmp(data,"{\\rtf1",6)==0&&
        (data[6]==' '||data[6]=='\\'||data[6]=='\r'||data[6]=='\n') && (data[size-1]=='}'||(size>1&&data[size-1]==0&&data[size-2]=='}'));
}
std::optional<RdpClipboardFormat> identify(uint32_t id,const char* name) {
    if (id==13) return RdpClipboardFormat::Text;
    if (id==17) return RdpClipboardFormat::DibV5;
    if (!id||!name) return {};
    if (!std::strcmp(name,"PNG")||!std::strcmp(name,"image/png")) return RdpClipboardFormat::Png;
    if (!std::strcmp(name,"HTML Format")) return RdpClipboardFormat::Html;
    if (!std::strcmp(name,"Rich Text Format")) return RdpClipboardFormat::Rtf;
    return {};
}
bool encode(const RdpClipboardContent& content,RdpClipboardWireContent& result) {
    result.items.clear(); RdpClipboardWireContent out;
    auto add=[&](RdpClipboardFormat format,uint32_t id,const char* name,std::vector<uint8_t> bytes) { out.items.push_back({format,id,name,std::move(bytes)}); };
    std::vector<uint8_t> bytes;
    if (content.textUtf8) { if (!RdpClipboardCodec::encode(*content.textUtf8,bytes)) return false; add(RdpClipboardFormat::Text,13,"",std::move(bytes)); }
    if (!content.png.empty()) { uint32_t w,h; if (!validatePng(content.png.data(),content.png.size(),w,h)) return false; if (!content.rgbaStraight.empty()&&(w!=content.width||h!=content.height)) return false; add(RdpClipboardFormat::Png,0,"PNG",content.png); }
    if (!content.rgbaStraight.empty()) { if (!encodeDibV5(content.rgbaStraight,content.width,content.height,bytes)) return false; add(RdpClipboardFormat::DibV5,17,"",std::move(bytes)); }
    else if (content.width||content.height) return false;
    if (content.htmlUtf8) { if (!encodeHtml(*content.htmlUtf8,bytes)) return false; add(RdpClipboardFormat::Html,0,"HTML Format",std::move(bytes)); }
    if (!content.rtfBytes.empty()) { if (!validateRtf(content.rtfBytes.data(),content.rtfBytes.size())) return false; add(RdpClipboardFormat::Rtf,0,"Rich Text Format",content.rtfBytes); }
    if (out.items.empty()) return false; result=std::move(out); return true;
}
bool decode(RdpClipboardFormat format,const uint8_t* data,size_t size,RdpClipboardContent& result) {
    result={};
    switch (format) {
    case RdpClipboardFormat::Text: { std::string text; if (!RdpClipboardCodec::decode(data,size,text)) return false; result.textUtf8=std::move(text); return true; }
    case RdpClipboardFormat::Png: if (!validatePng(data,size,result.width,result.height)) return false; result.png.assign(data,data+size); return true;
    case RdpClipboardFormat::DibV5: return decodeDibV5(data,size,result);
    case RdpClipboardFormat::Html: { std::string html; if (!decodeHtml(data,size,html)) return false; result.htmlUtf8=std::move(html); return true; }
    case RdpClipboardFormat::Rtf: if (!validateRtf(data,size)) return false; result.rtfBytes.assign(data,data+size); return true;
    }
    return false;
}
}
