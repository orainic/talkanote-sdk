/// CRC-16/XMODEM: polynomial 0x1021, initial value 0, no reflection, no final XOR.
///
/// The card computes it over the two LEN bytes of the frame header followed by
/// the DATA bytes.
int crc16Xmodem(List<int> bytes) {
  var crc = 0;
  for (final b in bytes) {
    crc ^= (b & 0xFF) << 8;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
    }
  }
  return crc;
}
