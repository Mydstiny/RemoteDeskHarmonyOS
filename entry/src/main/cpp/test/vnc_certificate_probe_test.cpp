/** Native VNC certificate probe error-category tests. */
#include "test_runner.h"
#include "vnc/vnc_certificate_probe.h"

#include <string>

RDP_TEST_CASE(vnc_certificate_probe_error_categories_are_stable) {
    RDP_ASSERT(vncCertificateProbeErrorCategory(
        static_cast<int>(VncCertificateProbeErrorCode::ConnectTimeout)) == "connect_timeout");
    RDP_ASSERT(vncCertificateProbeErrorCategory(
        static_cast<int>(VncCertificateProbeErrorCode::TlsHandshakeFailed)) == "tls_handshake_failed");
    RDP_ASSERT(vncCertificateProbeErrorCategory(9999) == "unknown");
    RDP_ASSERT(vncCertificateProbeErrorMessage(
        static_cast<int>(VncCertificateProbeErrorCode::Cancelled)).find("E-VNC-CERT-CANCELLED")
        != std::string::npos);
}
