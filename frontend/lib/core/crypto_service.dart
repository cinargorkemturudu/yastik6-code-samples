import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Wrong passphrase, or the backup was corrupted/tampered with (GCM tag mismatch).
class BackupDecryptionException implements Exception {
  const BackupDecryptionException();
  @override
  String toString() =>
      'BackupDecryptionException: wrong passphrase or corrupted backup';
}

/// Encrypts cloud backups with a key derived from a user passphrase, so a backup
/// can be restored on any device (the key is never stored anywhere).
///
/// File layout: magic "Y6BK" | version (1) | PBKDF2 iterations (uint32 BE) | salt (16) | nonce (12) | AES-256-GCM ciphertext + 16-byte tag.
/// The header is passed to GCM as associated data, so tampering with it is detected too.
class CryptoService {
  static const int defaultIterations = 210000;
  static const int _version = 2;
  static const int _saltLength = 16;
  static const int _nonceLength = 12;
  static const int _headerLength = 4 + 1 + 4 + _saltLength + _nonceLength;
  static final Uint8List _magic = Uint8List.fromList(ascii.encode('Y6BK'));

  /// PBKDF2 iteration count for new backups. Decryption always uses the count stored in the file.
  final int iterations;
  final Random _random;

  CryptoService({this.iterations = defaultIterations, Random? random})
    : _random = random ?? Random.secure();

  /// Key derivation is deliberately slow, so the work runs on a background isolate to keep the UI responsive.
  Future<Uint8List> encryptBackup(List<int> data, String passphrase) {
    final salt = _randomBytes(_saltLength);
    final nonce = _randomBytes(_nonceLength);
    final header =
        (BytesBuilder()
              ..add(_magic)
              ..addByte(_version)
              ..add(_uint32(iterations))
              ..add(salt)
              ..add(nonce))
            .toBytes();
    final plain = Uint8List.fromList(data);
    final iterationCount = iterations;

    return Isolate.run(() {
      final key = _deriveKey(passphrase, salt, iterationCount);
      final body = _gcm(true, key, nonce, header, plain);
      return (BytesBuilder(copy: false)
            ..add(header)
            ..add(body))
          .toBytes();
    });
  }

  /// Throws [FormatException] if [payload] is not a Yastık6 backup,
  /// and [BackupDecryptionException] if the passphrase is wrong or the file was altered.
  Future<Uint8List> decryptBackup(Uint8List payload, String passphrase) async {
    if (payload.length < _headerLength + 16 || !_startsWithMagic(payload)) {
      throw const FormatException('Not a Yastık6 backup file.');
    }
    if (payload[4] != _version) {
      throw FormatException('Unsupported backup version: ${payload[4]}');
    }

    final header = Uint8List.sublistView(payload, 0, _headerLength);
    final iterationCount = ByteData.sublistView(payload, 5, 9).getUint32(0);
    final salt = Uint8List.sublistView(payload, 9, 9 + _saltLength);
    final nonce = Uint8List.sublistView(
      payload,
      9 + _saltLength,
      _headerLength,
    );
    final body = Uint8List.sublistView(payload, _headerLength);

    return Isolate.run(() {
      final key = _deriveKey(passphrase, salt, iterationCount);
      try {
        return _gcm(false, key, nonce, header, body);
      } on InvalidCipherTextException {
        throw const BackupDecryptionException();
      }
    });
  }

  static Uint8List _deriveKey(
    String passphrase,
    Uint8List salt,
    int iterationCount,
  ) {
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, iterationCount, 32));
    return derivator.process(Uint8List.fromList(utf8.encode(passphrase)));
  }

  static Uint8List _gcm(
    bool encrypt,
    Uint8List key,
    Uint8List nonce,
    Uint8List aad,
    Uint8List input,
  ) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(encrypt, AEADParameters(KeyParameter(key), 128, nonce, aad));
    return cipher.process(input);
  }

  bool _startsWithMagic(Uint8List payload) {
    for (var i = 0; i < _magic.length; i++) {
      if (payload[i] != _magic[i]) return false;
    }
    return true;
  }

  Uint8List _randomBytes(int length) =>
      Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));

  static Uint8List _uint32(int value) =>
      (ByteData(4)..setUint32(0, value)).buffer.asUint8List();
}
