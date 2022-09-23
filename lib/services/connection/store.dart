import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sticker_import/generated/emoji_metadata.dart';
import 'package:sticker_import/utils/debugging.dart';

import 'account.dart';

class VkStickerStore {
  VkStickerStore({required this.account});

  final Account account;

  Stream<VkStickerStoreSection> _getSectionsStream() async* {
    final req = await account.vk.call(
      'catalog.getStickers',
      <String, String>{},
      isTraced: false,
    );

    final sections =
        (((req.asJson()['response'] as Map<String, dynamic>)['catalog']
                as Map<String, dynamic>)['sections'] as List<dynamic>)
            .cast<Map<String, dynamic>>();

    for (final section in sections) {
      yield VkStickerStoreSection(
        id: section['id'] as String,
        title: section['title'] as String,
        account: account,
      );
    }
  }

  Future<List<VkStickerStoreSection>> getSections() {
    return _getSectionsStream().toList();
  }
}

class BackgroundComputationResultVkStoreLayout {
  final List<VkStickerStoreLayout> list;
  final String? nextFrom;

  const BackgroundComputationResultVkStoreLayout(this.list, this.nextFrom);
}

BackgroundComputationResultVkStoreLayout _decodeRequest(
    List<List<int>> response) {
  final list = <VkStickerStoreLayout>[];
  final data =
      jsonDecode(utf8.decode(response.expand((element) => element).toList()))
          as Map<String, dynamic>;
  final Map<String, dynamic> packs;

  if (data['response']['stickers_packs'] != null) {
    packs = data['response']['stickers_packs'] as Map<String, dynamic>;
  } else if (data['response']['packs'] != null) {
    packs = (data['response']['packs'] as List<dynamic>)
        .asMap()
        .map<String, dynamic>((key, dynamic value) => MapEntry<String, dynamic>(
              value['product']['id'].toString(),
              value,
            ));
  } else {
    packs = <String, dynamic>{};
  }

  VkStickerStoreStickerAndPack findSticker(int id) {
    for (final pack in packs.values) {
      final stickers = pack['product']['stickers'] as List<dynamic>;
      for (final sticker in stickers) {
        if (sticker['sticker_id'] == id) {
          final p = VkStickerStorePack.fromJson(pack as Map<String, dynamic>);
          return VkStickerStoreStickerAndPack(
              sticker: p.styles[0].stickers!.firstWhere(
                (element) => element.id == id,
              ),
              pack: p);
        }
      }
    }

    iLog('No pack provided for a sticker ID $id');
    return VkStickerStoreStickerAndPack(
      sticker: VkStickerStoreSticker(
        id: id,
        image: 'https://vk.com/images/sticker/1-$id-512',
        thumbnail: 'https://vk.com/images/sticker/1-$id-128b',
      ),
      pack: null,
    );
  }

  final List<Map<String, dynamic>> blocks;
  final String? nextFrom;

  if (data['response']['section'] != null) {
    blocks = (data['response']['section']['blocks'] as List<dynamic>)
        .cast<Map<String, dynamic>>();

    nextFrom = data['response']['section']['next_from'] as String?;
  } else {
    blocks = (data['response']['blocks'] as List<dynamic>)
        .cast<Map<String, dynamic>>();

    nextFrom = data['response']['next_from'] as String?;
  }

  for (final block in blocks) {
    if (block['data_type'] == 'stickers_packs') {
      final packList = (block['stickers_pack_ids'] as List<dynamic>)
          .map((dynamic e) => e.toString());

      list.add(
        VkStickerStoreLayoutPackList(
          id: block['id'] as String,
          type: (block['layout']['name'] == 'slider')
              ? VkStickerStoreLayoutPackListType.slider
              : VkStickerStoreLayoutPackListType.list,
          packs: [
            for (final packId in packList)
              VkStickerStorePack.fromJson(
                packs[packId] as Map<String, dynamic>,
              )
          ],
        ),
      );
    } else if (block['pack_ids'] != null) {
      final packList =
          (block['pack_ids'] as List<dynamic>).map((dynamic e) => e.toString());

      list.add(
        VkStickerStoreLayoutHeader(
          id: block['id'] as String,
          title: block['title'] as String,
          buttons: [],
        ),
      );

      list.add(
        VkStickerStoreLayoutPackList(
          id: block['id'] as String,
          type: VkStickerStoreLayoutPackListType.slider,
          packs: [
            for (final packId in packList)
              VkStickerStorePack.fromJson(
                packs[packId] as Map<String, dynamic>,
              )
          ],
        ),
      );
    } else if (block['data_type'] == 'stickers') {
      list.add(VkStickerStoreLayoutStickersList(
        id: block['id'] as String,
        stickers: [
          for (final sticker
              in (block['sticker_ids'] as List<dynamic>).cast<int>())
            findSticker(sticker),
        ],
      ));
    } else if (block['layout']['name'] == 'header' ||
        block['layout']['name'] == 'header_compact') {
      list.add(VkStickerStoreLayoutHeader(
        id: block['id'] as String,
        title: block['layout']['title'] as String,
        buttons: [
          for (final button
              in (block['buttons'] as List<dynamic>? ?? <dynamic>[])
                  .cast<Map<String, dynamic>>())
            if (button['action']['type'] == 'open_section')
              VkStickerStoreLayoutSectionButton(
                title: button['title'] as String,
                sectionId: button['section_id'] as String,
              )
        ],
      ));
    } else if (block['layout']['name'] == 'separator') {
      list.add(VkStickerStoreLayoutSeparator(id: block['id'] as String));
    } else {
      iLog('Unknown block type: ${jsonEncode(block)}');
    }
  }

  return BackgroundComputationResultVkStoreLayout(list, nextFrom);
}

class VkStickerStoreSection {
  VkStickerStoreSection({
    required this.title,
    required this.id,
    required this.account,
  });

  final String title;
  final String id;
  final Account account;

  Future<BackgroundComputationResultVkStoreLayout> getPageContent(
      String? nextFrom) async {
    if (_contentCache.containsKey(nextFrom)) {
      return _contentCache[nextFrom]!;
    }

    final completer = Completer<BackgroundComputationResultVkStoreLayout>();
    _contentCache[nextFrom] = completer.future;

    scheduleMicrotask(() async {
      final data = (await account.vk.call(
        'catalog.getSection',
        <String, String>{
          'section_id': id,
          'extended': '1',
          if (nextFrom != null) 'start_from': nextFrom,
        },
        isTraced: false,
        lazyInterpretation: true,
      ));
      data.allowInterpretation!(false);

      final BackgroundComputationResultVkStoreLayout res =
          await compute(_decodeRequest, await data.response.toList());

      completer.complete(res);
    });

    return _contentCache[nextFrom]!;
  }

  Stream<VkStickerStoreLayout> getAllContent() async* {
    String? nextFrom;

    do {
      final res = await getPageContent(nextFrom);
      if (res.list.isEmpty) break;
      yield* Stream.fromIterable(res.list);
      nextFrom = res.nextFrom;
    } while (nextFrom != null);
  }

  final _contentCache =
      <String?, Future<BackgroundComputationResultVkStoreLayout>>{};

  Future<VkStickerStoreContent> getContentAsList() async {
    return VkStickerStoreContent(
      layout: await getAllContent().toList(),
    );
  }
}

class VkStickerStoreContent {
  final List<VkStickerStoreLayout> layout;

  const VkStickerStoreContent({required this.layout});
}

abstract class VkStickerStoreLayout {
  String? get id;
}

class VkStickerStoreLayoutHeader implements VkStickerStoreLayout {
  final String title;
  final List<VkStickerStoreLayoutSectionButton> buttons;
  @override
  final String id;

  const VkStickerStoreLayoutHeader({
    required this.title,
    required this.buttons,
    required this.id,
  });
}

class VkStickerStoreLayoutSectionButton {
  final String title;
  final String sectionId;

  const VkStickerStoreLayoutSectionButton({
    required this.title,
    required this.sectionId,
  });
}

class VkStickerStoreLayoutSeparator implements VkStickerStoreLayout {
  @override
  final String id;

  const VkStickerStoreLayoutSeparator({required this.id});
}

enum VkStickerStoreLayoutPackListType {
  slider,
  list,
}

class VkStickerStoreLayoutPackList implements VkStickerStoreLayout {
  final List<VkStickerStorePack> packs;
  final VkStickerStoreLayoutPackListType type;
  @override
  final String id;

  const VkStickerStoreLayoutPackList({
    required this.packs,
    required this.type,
    required this.id,
  });
}

class VkStickerStoreStickerAndPack {
  final VkStickerStoreSticker sticker;
  final VkStickerStorePack? pack;

  const VkStickerStoreStickerAndPack({
    required this.sticker,
    required this.pack,
  });
}

class VkStickerStoreLayoutStickersList implements VkStickerStoreLayout {
  final List<VkStickerStoreStickerAndPack> stickers;
  @override
  final String id;

  const VkStickerStoreLayoutStickersList({
    required this.stickers,
    required this.id,
  });
}

class VkStickerStoreLayoutLoader implements VkStickerStoreLayout {
  const VkStickerStoreLayoutLoader();

  @override
  String? get id => null;
}

class VkStickerStorePack {
  final int id;
  final String domain;
  final String title;
  final String description;
  final String author;
  final String image;
  final List<VkStickerStoreStyle> styles;

  VkStickerStorePack({
    required this.id,
    required this.domain,
    required this.title,
    required this.description,
    required this.author,
    required this.image,
    required this.styles,
  });

  factory VkStickerStorePack.fromJson(Map<String, dynamic> json) {
    final hasAnimation = json['product']['has_animation'] as bool? ?? false;
    return VkStickerStorePack(
      id: json['product']['id'] as int,
      domain: json['product']['url'] as String,
      title: json['product']['title'] as String,
      description: json['description'] as String,
      author: json['author'] as String,
      image: json['product']['icon'][1]['url'] as String,
      styles: [
        VkStickerStoreStyle(
          id: json['product']['id'] as int,
          domain: json['product']['url'] as String,
          title: json['product']['title'] as String,
          image: json['product']['icon'][1]['url'] as String,
          isAnimated: hasAnimation,
          stickers: [
            for (final sticker in json['product']['stickers'] as List<dynamic>)
              VkStickerStoreSticker(
                id: sticker['sticker_id'] as int,
                thumbnail:
                    sticker['images_with_background'][1]['url'] as String,
                image: (hasAnimation
                    ? sticker['animation_url'] as String
                    : sticker['images'][3]['url'] as String),
              ),
          ],
        ),
      ],
    );
  }

  Stream<VkStickerStoreLayout> _getContent(Account account) async* {
    String? nextFrom;

    do {
      final data = (await account.vk.call(
        'store.getStickerPacksRecommendationBlocks',
        <String, String>{
          'pack_id': id.toString(),
          'extended': '1',
          if (nextFrom != null) 'start_from': nextFrom,
        },
        isTraced: false,
        lazyInterpretation: true,
      ));
      data.allowInterpretation!(false);

      final BackgroundComputationResultVkStoreLayout res =
          await compute(_decodeRequest, await data.response.toList());

      if (res.list.isEmpty) break;

      yield* Stream.fromIterable(res.list);
      nextFrom = res.nextFrom;
    } while (nextFrom != null);
  }

  VkStickerStoreContent? _contentCache;

  Future<VkStickerStoreContent> getContent(Account account) async {
    _contentCache ??=
        VkStickerStoreContent(layout: await _getContent(account).toList());
    return _contentCache!;
  }
}

class VkStickerStoreStyle {
  final int id;
  final String domain;
  final bool isAnimated;
  final String title;
  final String image;
  final List<VkStickerStoreSticker>? stickers;

  const VkStickerStoreStyle({
    required this.id,
    required this.domain,
    required this.isAnimated,
    required this.title,
    required this.image,
    this.stickers,
  });

  Future<void> updateKeywords(Account account) async {
    final List<dynamic> data = ((await account.vk.call(
      'store.getStickersKeywords',
      <String, String>{
        'products_ids': id.toString(),
      },
    ))
            .asJson() as Map<String, dynamic>)['response']['dictionary']
        as List<dynamic>;

    for (final keywords in data) {
      final emoji = (keywords['words'] as List<dynamic>)
          .map((dynamic e) => kEmojiAtlas.filterEmoji(e as String))
          .expand<String>((element) =>
              element.where((element) => element.trim().isNotEmpty));

      final stickerList =
          (keywords['user_stickers'] as List<dynamic>? ?? <dynamic>[])
              .followedBy(
        keywords['promoted_stickers'] as List<dynamic>? ?? <dynamic>[],
      );

      for (final userSticker in stickerList) {
        final VkStickerStoreSticker sticker;

        try {
          sticker = stickers!.firstWhere(
            (element) => element.id == userSticker['sticker_id'],
          );
        } on StateError {
          continue;
        }

        if (sticker.suggestions == null) {
          sticker.suggestions = emoji.toList();
        } else {
          sticker.suggestions!.addAll(emoji);
        }
      }
    }
  }
}

class VkStickerStoreSticker {
  final int id;
  final String thumbnail;
  final String image;
  List<String>? suggestions;

  VkStickerStoreSticker({
    required this.id,
    required this.thumbnail,
    required this.image,
    this.suggestions,
  });
}
