import 'dart:convert';

import 'package:enough_convert/windows/windows1252.dart';
import 'package:vkget/vkget.dart';

Future<int?> stickerUrlToId(VKGet client, Uri url) async {
  final req = await client.fetch(
    url,
    overrideUserAgent:
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.114 Safari/537.36',
  );
  final html =
      await const Windows1252Codec(allowInvalid: false).decodeStream(req);
  final res =
      RegExp(r'Emoji.previewSticker\((\d+)\)').firstMatch(html)?.group(1);
  print(res);

  if (res != null) return int.tryParse(res);
}

Future<Map<String, dynamic>> getStickerJson(VKGet client, int id) async {
  final req = await client.fetch(
      Uri.parse('https://vk.com/stickers.php?act=preview_products_order'),
      method: 'POST',
      bodyFields: {
        'act': 'preview_products_order',
        'al': '1',
        'cart': '{"items":[{"product_id":$id,"amount":1}],"recipient_ids":[]}',
        'with_suggested_recipients': '0',
      });
  final text =
      await const Windows1252Codec(allowInvalid: false).decodeStream(req);
  return jsonDecode(text.substring(4)) as Map<String, dynamic>;
}
