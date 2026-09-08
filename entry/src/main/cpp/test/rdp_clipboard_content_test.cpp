#include "rdp/rdp_clipboard_content.h"
#include "test_runner.h"
#include <cstring>
using namespace RdpClipboardContentCodec;
namespace {
uint32_t crc(const uint8_t* p,size_t n) { uint32_t c=~0u; while(n--) {c^=*p++;for(int i=0;i<8;++i)c=(c>>1)^((0u-(c&1))&0xedb88320u);}return ~c; }
void big(std::vector<uint8_t>& b,uint32_t n) { for(int i=3;i>=0;--i)b.push_back(uint8_t(n>>(8*i))); }
void chunk(std::vector<uint8_t>& b,const char* type,const std::vector<uint8_t>& data) {big(b,data.size());auto start=b.size();b.insert(b.end(),type,type+4);b.insert(b.end(),data.begin(),data.end());big(b,crc(b.data()+start,data.size()+4));}
std::vector<uint8_t> png(uint32_t w=1,uint32_t h=1) {
    std::vector<uint8_t> b={137,80,78,71,13,10,26,10}, header;
    big(header,w);big(header,h);header.insert(header.end(),{8,6,0,0,0});chunk(b,"IHDR",header);
    // zlib: one transparent RGBA pixel, including filter byte.
    chunk(b,"IDAT",{120,156,99,96,0,2,0,0,5,0,1});chunk(b,"IEND",{});return b;
}
void little(std::vector<uint8_t>& b,size_t p,uint32_t n) {for(int i=0;i<4;++i)b[p+i]=uint8_t(n>>(8*i));}
}
RDP_TEST_CASE(rdp_rich_png_enforces_dimensions_chunks_and_crc) {
    uint32_t w=0,h=0;auto bytes=png();RDP_ASSERT(validatePng(bytes.data(),bytes.size(),w,h));RDP_ASSERT_EQ(w,1U);
    bytes[40]^=1;RDP_ASSERT(!validatePng(bytes.data(),bytes.size(),w,h));
    for(auto d:{0U,8193U,0xffffffffU}){bytes=png(d,1);RDP_ASSERT(!validatePng(bytes.data(),bytes.size(),w,h));}
    bytes=png(4096,2048);RDP_ASSERT(!validatePng(bytes.data(),bytes.size(),w,h));
    bytes=png(2048,2048);RDP_ASSERT(validatePng(bytes.data(),bytes.size(),w,h));
    bytes.push_back(0);RDP_ASSERT(!validatePng(bytes.data(),bytes.size(),w,h));
    bytes.resize(kMaxPngBytes+1);RDP_ASSERT(!validatePng(bytes.data(),bytes.size(),w,h));
}
RDP_TEST_CASE(rdp_rich_dibv5_roundtrips_alpha_and_both_row_orders) {
    std::vector<uint8_t> pixels={255,20,30,64,40,255,60,128}; std::vector<uint8_t> dib;
    RDP_ASSERT(encodeDibV5(pixels,1,2,dib));RdpClipboardContent result;
    RDP_ASSERT(decodeDibV5(dib.data(),dib.size(),result));RDP_ASSERT(result.rgbaStraight==pixels);
    little(dib,8,2);for(size_t i=0;i<4;++i)std::swap(dib[124+i],dib[128+i]);
    RDP_ASSERT(decodeDibV5(dib.data(),dib.size(),result));RDP_ASSERT(result.rgbaStraight==pixels);
}
RDP_TEST_CASE(rdp_rich_dibv5_rejects_profiles_masks_sizes_and_overflow) {
    std::vector<uint8_t> dib;RDP_ASSERT(encodeDibV5({1,2,3,4},1,1,dib));
    for(const auto offset:{0U,4U,8U,12U,14U,16U,20U,32U,36U,40U,44U,48U,52U,56U,60U,112U,116U,120U}) {
        auto bad=dib;bad[offset]^=0x80;RdpClipboardContent result;RDP_ASSERT(!decodeDibV5(bad.data(),bad.size(),result));
    }
    RdpClipboardContent result;RDP_ASSERT(!decodeDibV5(dib.data(),dib.size()-1,result));
    std::vector<uint8_t> output;RDP_ASSERT(!encodeDibV5({1,2,3,4},0xffffffff,0xffffffff,output));
}
RDP_TEST_CASE(rdp_rich_html_uses_utf8_byte_offsets_without_rendering) {
    const std::string fragment="<p>中文é</p><img src=\"https://untrusted.invalid/x\">";std::vector<uint8_t> wire;std::string decoded;
    RDP_ASSERT(encodeHtml(fragment,wire));RDP_ASSERT(decodeHtml(wire.data(),wire.size(),decoded));RDP_ASSERT(decoded==fragment);
    auto invalid=wire;const auto key=std::string("StartFragment:");auto text=std::string(invalid.begin(),invalid.end());auto at=text.find(key)+key.size();invalid[at]='-';
    RDP_ASSERT(!decodeHtml(invalid.data(),invalid.size(),decoded));
    invalid=wire;invalid[at]='9';RDP_ASSERT(!decodeHtml(invalid.data(),invalid.size(),decoded));
    RDP_ASSERT(!encodeHtml(std::string("a\0b",3),wire));RDP_ASSERT(!encodeHtml(std::string("\xc0\xaf",2),wire));
    RDP_ASSERT(!encodeHtml(std::string(kMaxRichBytes,'x'),wire));
}
RDP_TEST_CASE(rdp_rich_rtf_is_bounded_opaque_and_never_text_fallback) {
    const std::string rtf="{\\rtf1\\ansi opaque \\bin3 abc}";RdpClipboardContent out;
    RDP_ASSERT(decode(RdpClipboardFormat::Rtf,reinterpret_cast<const uint8_t*>(rtf.data()),rtf.size(),out));
    RDP_ASSERT(!out.textUtf8.has_value());RDP_ASSERT_EQ(out.rtfBytes.size(),rtf.size());
    RDP_ASSERT(!decode(RdpClipboardFormat::Rtf,reinterpret_cast<const uint8_t*>("plain"),5,out));
    std::vector<uint8_t> large(kMaxRichBytes+1,'x');RDP_ASSERT(!validateRtf(large.data(),large.size()));
}
RDP_TEST_CASE(rdp_rich_one_content_preserves_all_formats_and_plain_fallback) {
    RdpClipboardContent value;value.textUtf8="plain";value.htmlUtf8="<b>bold</b>";value.png=png();
    value.rgbaStraight={0,0,0,0};value.width=1;value.height=1;
    const std::string rtf="{\\rtf1 rich}";value.rtfBytes.assign(rtf.begin(),rtf.end());
    RdpClipboardWireContent wire;RDP_ASSERT(encode(value,wire));RDP_ASSERT_EQ(wire.items.size(),5U);
    value.width=2;RDP_ASSERT(!encode(value,wire));RDP_ASSERT(wire.items.empty());
    value={};value.htmlUtf8="<b>rich without fallback</b>";RDP_ASSERT(encode(value,wire));RDP_ASSERT_EQ(wire.items.size(),1U);
    RDP_ASSERT(wire.items[0].format==RdpClipboardFormat::Html);
}
RDP_TEST_CASE(rdp_rich_remote_registered_ids_are_mapped_by_name) {
    RDP_ASSERT(identify(0xc599,"PNG")==RdpClipboardFormat::Png);
    RDP_ASSERT(identify(0xdead,"HTML Format")==RdpClipboardFormat::Html);
    RDP_ASSERT(identify(17,nullptr)==RdpClipboardFormat::DibV5);
    RDP_ASSERT(!identify(0xc101,"unknown").has_value());
}
