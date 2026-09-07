//! Address-free evidence from messages actually handed to the session writer.
//! This is a separate versioned FFI snapshot; established stream/config ABIs do
//! not change. A successful write is not a server acknowledgement of the codec.
use crate::protocol::message_proto::{SupportedDecoding, SupportedDecoding_PreferCodec, SupportedEncoding};
use protobuf::ProtobufEnum;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct RustDeskCodecEvidence {
    pub version: u32,
    pub requested_preference: i32,
    pub sent_preference: i32,
    pub wire_preference: i32,
    pub advertised_mask: u32,
    pub peer_encoding_mask: i32,
    pub last_send_stage: u32, // 0=none, 1=login write, 2=runtime write, 3=runtime enqueue
    pub reserved: u32, // most recently enqueued preference + 1; 0=unknown
    pub login_sends: u64,
    pub option_sends: u64,
    pub send_failures: u64,
}

impl Default for RustDeskCodecEvidence {
    fn default() -> Self {
        Self { version: 1, requested_preference: -1, sent_preference: -1,
            wire_preference: -1, advertised_mask: 0, peer_encoding_mask: -1,
            last_send_stage: 0, reserved: 0, login_sends: 0, option_sends: 0,
            send_failures: 0 }
    }
}

impl RustDeskCodecEvidence {
    pub fn record_send(&mut self, requested: i32, decoding: &SupportedDecoding,
        stage: u32, succeeded: bool) {
        self.requested_preference = requested;
        self.last_send_stage = stage;
        if !succeeded {
            self.send_failures = self.send_failures.saturating_add(1);
            return;
        }
        let preference = match decoding.get_prefer() {
            SupportedDecoding_PreferCodec::VP8 => 1,
            SupportedDecoding_PreferCodec::VP9 => 2,
            SupportedDecoding_PreferCodec::AV1 => 3,
            SupportedDecoding_PreferCodec::H264 => 4,
            SupportedDecoding_PreferCodec::H265 => 5,
            SupportedDecoding_PreferCodec::Auto => 0,
        };
        if stage == 3 {
            self.reserved = (preference + 1) as u32;
            self.option_sends = self.option_sends.saturating_add(1);
            return;
        }
        self.wire_preference = decoding.get_prefer().value();
        self.sent_preference = preference;
        // Bit positions match the actual-frame codec IDs, not preference IDs.
        self.advertised_mask = u32::from(decoding.get_ability_h264() > 0)
            | (u32::from(decoding.get_ability_h265() > 0) << 1)
            | (u32::from(decoding.get_ability_vp8() > 0) << 2)
            | (u32::from(decoding.get_ability_vp9() > 0) << 3)
            | (u32::from(decoding.get_ability_av1() > 0) << 4);
        if stage == 1 { self.login_sends = self.login_sends.saturating_add(1); }
        if stage == 2 { self.option_sends = self.option_sends.saturating_add(1); }
    }

    pub fn record_peer_encoding(&mut self, encoding: &SupportedEncoding) {
        // VP9 is the protocol baseline and has no SupportedEncoding field.
        self.peer_encoding_mask = i32::from(encoding.get_h264())
            | (i32::from(encoding.get_h265()) << 1)
            | (i32::from(encoding.get_vp8()) << 2) | (1 << 3)
            | (i32::from(encoding.get_av1()) << 4);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn failed_write_does_not_claim_a_sent_preference() {
        let mut state = RustDeskCodecEvidence::default();
        let mut decoding = SupportedDecoding::new();
        decoding.set_prefer(SupportedDecoding_PreferCodec::H265);
        decoding.set_ability_h265(1);
        state.record_send(5, &decoding, 1, false);
        assert_eq!((state.sent_preference, state.login_sends, state.send_failures), (-1, 0, 1));
        state.record_send(5, &decoding, 1, true);
        assert_eq!((state.sent_preference, state.wire_preference, state.advertised_mask), (5, 3, 2));
        decoding.set_prefer(SupportedDecoding_PreferCodec::H264);
        state.record_send(4, &decoding, 2, false);
        assert_eq!((state.requested_preference, state.sent_preference, state.option_sends), (4, 5, 0));
    }
    #[test]
    fn queued_runtime_option_never_overwrites_confirmed_login_write() {
        let mut state = RustDeskCodecEvidence::default();
        let mut decoding = SupportedDecoding::new();
        decoding.set_prefer(SupportedDecoding_PreferCodec::H265);
        state.record_send(5, &decoding, 1, true);
        decoding.set_prefer(SupportedDecoding_PreferCodec::H264);
        state.record_send(4, &decoding, 3, true);
        assert_eq!((state.sent_preference, state.wire_preference), (5, 3));
        assert_eq!((state.reserved, state.option_sends, state.last_send_stage), (5, 1, 3));
    }
    #[test]
    fn absent_peer_capability_stays_unknown_and_ffi_layout_is_fixed() {
        let mut state = RustDeskCodecEvidence::default();
        assert_eq!(state.peer_encoding_mask, -1);
        state.record_peer_encoding(&SupportedEncoding::new());
        assert_eq!(state.peer_encoding_mask, 8);
        assert_eq!(std::mem::size_of::<RustDeskCodecEvidence>(), 56);
        assert_eq!(std::mem::align_of::<RustDeskCodecEvidence>(), 8);
    }
}
