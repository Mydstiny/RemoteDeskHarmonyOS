// opus_ffi.rs — 最小 libopus FFI 绑定 (decode only)
// 替代 magnum-opus，避免 bindgen + cross-compilation 问题
// libopus 必须先用 scripts/build_opus_ohos.sh 交叉编译

#![allow(non_camel_case_types, dead_code)]

use std::os::raw::{c_char, c_float, c_int, c_uchar};

pub const OPUS_APPLICATION_VOIP: c_int = 2048;
pub const OPUS_APPLICATION_AUDIO: c_int = 2049;
pub const OPUS_APPLICATION_RESTRICTED_LOWDELAY: c_int = 2051;

pub const OPUS_SET_GAIN_REQUEST: c_int = 4034;
pub const OPUS_GET_GAIN_REQUEST: c_int = 4045;

pub const OPUS_OK: c_int = 0;
pub const OPUS_BAD_ARG: c_int = -1;
pub const OPUS_BUFFER_TOO_SMALL: c_int = -2;
pub const OPUS_INTERNAL_ERROR: c_int = -3;
pub const OPUS_INVALID_PACKET: c_int = -4;
pub const OPUS_UNIMPLEMENTED: c_int = -5;
pub const OPUS_INVALID_STATE: c_int = -6;
pub const OPUS_ALLOC_FAIL: c_int = -7;

pub type opus_int32 = i32;
pub type opus_uint32 = u32;

#[repr(C)]
pub struct OpusDecoder {
    _private: [u8; 0],
}

#[repr(C)]
pub struct OpusMSDecoder {
    _private: [u8; 0],
}

#[link(name = "opus", kind = "static")]
extern "C" {
    pub fn opus_decoder_create(
        sample_rate: opus_int32,
        channels: c_int,
        error: *mut c_int,
    ) -> *mut OpusDecoder;
    pub fn opus_decoder_destroy(st: *mut OpusDecoder);
    pub fn opus_decode_float(
        st: *mut OpusDecoder,
        data: *const c_uchar,
        len: opus_int32,
        pcm: *mut c_float,
        frame_size: c_int,
        decode_fec: c_int,
    ) -> c_int;
    pub fn opus_decoder_ctl(st: *mut OpusDecoder, request: c_int, ...) -> c_int;
    pub fn opus_packet_get_nb_frames(data: *const c_uchar, len: opus_int32) -> c_int;
    pub fn opus_packet_get_samples_per_frame(
        data: *const c_uchar,
        sample_rate: opus_int32,
    ) -> c_int;

    // Multistream (optional, for surround / multichannel)
    pub fn opus_multistream_decoder_create(
        sample_rate: opus_int32,
        channels: c_int,
        nb_streams: c_int,
        nb_coupled: c_int,
        mapping: *const c_uchar,
        error: *mut c_int,
    ) -> *mut OpusMSDecoder;
    pub fn opus_multistream_decoder_destroy(st: *mut OpusMSDecoder);
    pub fn opus_multistream_decode_float(
        st: *mut OpusMSDecoder,
        data: *const c_uchar,
        len: opus_int32,
        pcm: *mut c_float,
        frame_size: c_int,
        decode_fec: c_int,
    ) -> c_int;
}

/// Safe wrapper around OpusDecoder
pub struct OpusDecoderHandle {
    inner: *mut OpusDecoder,
    channels: u32,
}

impl OpusDecoderHandle {
    pub fn new(sample_rate: u32, channels: u32) -> Result<Self, c_int> {
        let mut error: c_int = 0;
        let inner = unsafe {
            opus_decoder_create(sample_rate as opus_int32, channels as c_int, &mut error)
        };
        if error != OPUS_OK || inner.is_null() {
            Err(error)
        } else {
            Ok(Self { inner, channels })
        }
    }

    pub fn decode_float(
        &mut self,
        data: &[u8],
        pcm_out: &mut [f32],
        decode_fec: bool,
    ) -> Result<usize, c_int> {
        let frame_size = pcm_out.len() / self.channels as usize;
        let ret = unsafe {
            opus_decode_float(
                self.inner,
                data.as_ptr(),
                data.len() as opus_int32,
                pcm_out.as_mut_ptr(),
                frame_size as c_int,
                decode_fec as c_int,
            )
        };
        if ret < 0 {
            Err(ret)
        } else {
            Ok((ret as usize) * self.channels as usize)
        }
    }
}

impl Drop for OpusDecoderHandle {
    fn drop(&mut self) {
        if !self.inner.is_null() {
            unsafe { opus_decoder_destroy(self.inner) };
            self.inner = std::ptr::null_mut();
        }
    }
}

// Safety: OpusDecoder can be sent across threads
unsafe impl Send for OpusDecoderHandle {}
