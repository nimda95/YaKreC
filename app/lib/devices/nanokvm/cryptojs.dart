import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// CryptoJS-compatible `AES.encrypt(plaintext, passphrase).toString()`.
///
/// When CryptoJS is handed a string passphrase (not an explicit key+IV) it
/// uses OpenSSL's "salted" format:
///   * 8 random bytes of salt
///   * EVP_BytesToKey with MD5 derives a 32-byte AES-256 key + 16-byte IV
///   * AES-256-CBC, PKCS7 padding
///   * Output bytes: ASCII "Salted__" || salt || ciphertext, base64-encoded
///
/// The result decrypts with `openssl enc -aes-256-cbc -md md5 -pass pass:...`.
String cryptoJsAesEncrypt(String plaintext, String passphrase) {
  final salt = _randomBytes(8);
  final keyAndIv = _evpBytesToKey(
    Uint8List.fromList(utf8.encode(passphrase)),
    salt,
    32 + 16,
  );
  final key = Uint8List.sublistView(keyAndIv, 0, 32);
  final iv = Uint8List.sublistView(keyAndIv, 32, 48);

  final cipher = PaddedBlockCipherImpl(
    PKCS7Padding(),
    CBCBlockCipher(AESEngine()),
  )..init(
      true,
      PaddedBlockCipherParameters(
        ParametersWithIV(KeyParameter(key), iv),
        null,
      ),
    );
  final ciphertext =
      cipher.process(Uint8List.fromList(utf8.encode(plaintext)));

  final out = BytesBuilder()
    ..add(ascii.encode('Salted__'))
    ..add(salt)
    ..add(ciphertext);
  return base64Encode(out.toBytes());
}

Uint8List _randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

/// OpenSSL EVP_BytesToKey with MD5, one iteration. Hashes
/// `prev || password || salt` repeatedly until [needed] bytes are produced.
Uint8List _evpBytesToKey(Uint8List password, Uint8List salt, int needed) {
  final md5 = MD5Digest();
  final builder = BytesBuilder();
  Uint8List prev = Uint8List(0);
  while (builder.length < needed) {
    md5.reset();
    md5.update(prev, 0, prev.length);
    md5.update(password, 0, password.length);
    md5.update(salt, 0, salt.length);
    final out = Uint8List(md5.digestSize);
    md5.doFinal(out, 0);
    prev = out;
    builder.add(out);
  }
  return Uint8List.fromList(builder.toBytes().sublist(0, needed));
}
