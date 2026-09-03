# App Store Metadata, Data Safety, and Privacy Declarations

This document specifies the exact declarations to be filed for Google Play Console and Apple App Store Connect.

---

## 1. Google Play Console: Data Safety Form

### Overview
OneShare is an offline, peer-to-peer, local network file transfer utility. **Zero data is collected, zero data is stored on remote servers, and zero data is shared with third parties.**

### Data Collection & Sharing Declaration
- **Does your app collect or share any user data?**: **No**
- **Data collected**: **None**
- **Data shared**: **None**
- **Is all data encrypted in transit?**: **Yes** (E2EE v2 with Ed25519 authenticated key exchange and XChaCha20-Poly1305 AEAD authenticated cipher streams over the local network).
- **Account creation**: **No account required**.
- **Can users request data deletion?**: **Not applicable** (no user data or accounts exist to delete; identity keys and transfer history are stored purely on-device and can be cleared instantly in the app via Settings -> Reset Identity).

### Android Permissions Justification
1. **`android.permission.NEARBY_WIFI_DEVICES`** (`usesPermissionFlags="neverForLocation"`):
   - **Reason**: Enables discovering nearby peer devices on the same Wi-Fi network and Wi-Fi Direct interfaces on Android 13+ (API 33+) without querying user location.
2. **`android.permission.ACCESS_FINE_LOCATION`** (`maxSdkVersion="32"`):
   - **Reason**: Backward compatibility for Wi-Fi network state and SSID discovery on legacy Android 12 and below (API <= 32). Scoped to `maxSdkVersion="32"` so modern devices are not prompted for location.
3. **`android.permission.INTERNET`**, **`ACCESS_NETWORK_STATE`**, **`ACCESS_WIFI_STATE`**, **`CHANGE_WIFI_MULTICAST_STATE`**:
   - **Reason**: Required for local socket binding, network interface monitoring, and mDNS / DNS-SD multicast discovery across the local subnet.

### Cleartext Traffic Justification
- `android:usesCleartextTraffic="true"` is declared because P2P file transfers communicate directly with peer local DHCP IP addresses (e.g. `192.168.x.y:4040`).
- No cleartext unencrypted application data is transmitted: all payload streams and control messages are encrypted using XChaCha20-Poly1305 with session keys derived from authenticated Ed25519 SAS verification handshakes.

---

## 2. Apple App Store Connect: App Privacy (Privacy Nutrition Labels)

### Data Collection
- **Data Used to Track You**: **None**
- **Data Linked to You**: **None**
- **Data Not Linked to You**: **None**
- Under App Privacy, declare **"Data Not Collected"**. The app does not collect any data from this app.

### Apple Platform Permissions & Descriptions
1. **Local Network Usage (`NSLocalNetworkUsageDescription`)**:
   - String: `"OneShare uses your local network to discover nearby devices and transfer files."`
   - Justification: Required by iOS/macOS to discover and pair with nearby devices using Bonjour / mDNS.
2. **Bonjour Services (`NSBonjourServices`)**:
   - Entry: `_oneshare._tcp`
   - Justification: Registered mDNS service type used for discovering OneShare instances on the local subnet.
