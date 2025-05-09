// ignore_for_file: deprecated_member_use

import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:math";
import "package:dio/dio.dart";
import "package:dio/io.dart";
import "package:flutter/material.dart";
import "package:html/parser.dart";
import "package:unofficial_filman_client/types/exceptions.dart";

String getBaseUrl(final String url) {
  final uri = Uri.parse(url);
  return "${uri.scheme}://${uri.host}";
}

abstract class VideoScraper {
  final String url;

  VideoScraper(this.url);

  Future<String> getVideoLink();
}

enum Language implements Comparable {
  pl("PL"),
  dubbing("Dubbing"),
  lektor("Lektor"),
  dubbingKino("Dubbing_Kino"),
  lektorIVO("Lektor_IVO"),
  napisy("Napisy"),
  napisyTansl("Napisy_Tansl"),
  eng("ENG");

  const Language(this.language);
  final String language;

  @override
  int compareTo(final other) {
    return Language.values
        .indexOf(this)
        .compareTo(Language.values.indexOf(other));
  }

  @override
  String toString() => language;
}

enum Quality implements Comparable {
  p1080("1080p"),
  p720("720p"),
  p480("480p"),
  p360("360p");

  const Quality(this.quality);
  final String quality;

  @override
  int compareTo(final other) {
    return Quality.values
        .indexOf(this)
        .compareTo(Quality.values.indexOf(other));
  }

  @override
  String toString() => quality;
}

class StreamtapeScraper extends VideoScraper {
  StreamtapeScraper(super.url);

  @override
  Future<String> getVideoLink() async {
    final Dio dio = Dio();
    final response = await dio.get(url);

    final jsLineMatch = RegExp(
            r"(?<=document\.getElementById\('botlink'\)\.innerHTML = )(.*)(?=;)")
        .firstMatch(response.data);

    if (jsLineMatch == null || jsLineMatch.group(0) == null) {
      throw Exception("No JS line found");
    }

    final String jsLine = jsLineMatch.group(0)!;

    final List<String> urls = RegExp(r"'([^']*)'")
        .allMatches(jsLine)
        .map((final m) => m.group(0)!.replaceAll("'", ""))
        .toList();

    if (urls.length != 2) {
      throw Exception("No URL in JS line");
    }

    final String base = urls[0];
    final String encoded = urls[1];

    final String fullUrl = "https:$base${encoded.substring(4)}";

    final apiResponse = await dio.get(
      fullUrl,
      options: Options(
        followRedirects: false,
        validateStatus: (final status) =>
            status != null && status >= 200 && status < 400,
      ),
    );

    final String? directLink = apiResponse.headers["location"]?.first;

    if (directLink == null) {
      throw Exception("No direct link found");
    }

    return Uri.parse(directLink).toString();
  }

  static bool isSupported(final String url) {
    return url.contains("streamtape");
  }
}

class VidozaScraper extends VideoScraper {
  VidozaScraper(super.url);

  @override
  Future<String> getVideoLink() async {
    final Dio dio = Dio();
    final response = await dio.get(url);
    final document = parse(response.data);

    if (document.body?.text == "File was deleted") {
      throw const NoSourcesException();
    }

    final directLink = document.querySelector("source")?.attributes["src"];

    if (directLink == null) {
      throw const NoSourcesException();
    }

    return Uri.parse(directLink).toString();
  }

  static bool isSupported(final String url) {
    return url.contains("vidoza");
  }
}

class VtubeScraper extends VideoScraper {
  VtubeScraper(super.url);

  String deobfuscate(String p, final int a, int c, final List<String> k) {
    while (c-- > 0) {
      if (k[c] != "") {
        p = p.replaceAll(RegExp("\\b${c.toRadixString(a)}\\b"), k[c]);
      }
    }
    return p;
  }

  @override
  Future<String> getVideoLink() async {
    final Dio dio = Dio();
    final response = await dio.get(url,
        options: Options(headers: {"referer": "https://filman.cc/"}));

    final jsLineMatch = RegExp(
            r"(?<=<script type='text\/javascript'>eval\()(.*)(?=\)<\/script>)")
        .firstMatch(response.data.toString().replaceAll("\n", ""));

    if (jsLineMatch == null || jsLineMatch.group(0) == null) {
      throw const NoSourcesException();
    }

    final String jsLine = jsLineMatch.group(0)!;

    final removeStart = jsLine.replaceAll(
        "function(p,a,c,k,e,d){while(c--)if(k[c])p=p.replace(new RegExp('\\\\b'+c.toString(a)+'\\\\b','g'),k[c]);return p}(",
        "");

    final removeEnd = removeStart.substring(0, removeStart.length - 1);

    final firstArgMatch =
        RegExp(r"'([^'\\]*(?:\\.[^'\\]*)*)'").firstMatch(removeEnd);

    if (firstArgMatch == null || firstArgMatch.group(0) == null) {
      throw const NoSourcesException();
    }

    final firstArg = firstArgMatch.group(0)!;

    final stringWithoutFirstArg = removeEnd.replaceFirst(firstArg, "");

    final normalizedArgs =
        stringWithoutFirstArg.split(",").where((final i) => i.isNotEmpty);

    final int secondArg = int.parse(normalizedArgs.first);

    final int thirdArg = int.parse(normalizedArgs.elementAt(1));

    final fourthArg = normalizedArgs
        .elementAt(2)
        .replaceAll(".split('|')", "")
        .replaceAll("'", "")
        .split("|");

    final String decoded =
        deobfuscate(firstArg, secondArg, thirdArg, fourthArg);

    final directLink = decoded
        .split("jwplayer(\"vplayer\").setup({sources:[{file:\"")[1]
        .split("\"")[0];

    return Uri.parse(directLink).toString();
  }

  static bool isSupported(final String url) {
    return url.contains("vtube");
  }
}

class DoodStreamScraper extends VideoScraper {
  DoodStreamScraper(super.url);

  @override
  Future<String> getVideoLink() async {
    final Dio dio = Dio();
    _configureHttpClientAdapter(dio);

    final embedUrl = url.replaceAll("/d/", "/e/");
    final initialResponse = await dio.get(embedUrl, options: Options(
      followRedirects: true,
      validateStatus: (final status) => true,
    ));

    final host = getBaseUrl(initialResponse.redirects.isNotEmpty
        ? initialResponse.redirects.last.location.toString()
        : embedUrl);

    final responseText = initialResponse.data.toString();
    final md5Match = RegExp(r"/pass_md5/[^']*").firstMatch(responseText);

    if (md5Match == null) {
      throw Exception("Could not retrieve video link");
    }

    final md5Path = md5Match.group(0)!;
    final md5Url = host + md5Path;

    final md5Response = await dio.get(
      md5Url,
      options: Options(
        headers: {
          "Referer": embedUrl,
          "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
        },
        validateStatus: (final status) => true,
      ),
    );

    if (md5Response.statusCode != 200) {
      throw Exception("Could not retrieve video link");
    }

    final baseVideoUrl = md5Response.data.toString();
    final randomHash = _createHashTable();
    final token = md5Path.split("/").last;
    final expiry = DateTime.now().millisecondsSinceEpoch.toString();

    final trueUrl = "$baseVideoUrl$randomHash?token=$token&expiry=$expiry";
    return Uri.parse(trueUrl).toString();
  }

  void _configureHttpClientAdapter(final Dio dio) {
    final adapter = dio.httpClientAdapter;
    if (adapter is IOHttpClientAdapter) {
      adapter.createHttpClient = () {
        final client = HttpClient();
        client.badCertificateCallback =
            (final X509Certificate cert, final String host, final int port) => true;
        return client;
      };
    } else if (adapter is IOHttpClientAdapter) {
      adapter.onHttpClientCreate = (final client) {
        client.badCertificateCallback =
            (final X509Certificate cert, final String host, final int port) => true;
        return client;
      };
    } else {
      throw Exception("Could not retrieve video link");
    }
  }

  String _createHashTable() {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    final random = Random();
    return List.generate(
        10, (final _) => alphabet[random.nextInt(alphabet.length)]).join();
  }

  String getBaseUrl(final String url) {
    final uri = Uri.parse(url);
    return "${uri.scheme}://${uri.host}";
  }

  static bool isSupported(final String url) {
    final urls = [
      "https://d0000d.com", "https://d000d.com", "https://doodstream.com",
      "https://dooood.com", "https://dood.wf", "https://dood.cx",
      "https://dood.sh", "https://dood.watch", "https://dood.pm",
      "https://dood.to", "https://dood.so", "https://dood.ws",
      "https://dood.yt", "https://dood.li", "https://ds2play.com",
      "https://ds2video.com"
    ];
    return urls.any((final u) => url.contains(u));
  }
}

class VoeScraper extends VideoScraper {
  VoeScraper(super.url);

  @override
  Future<String> getVideoLink() async {
    final dio = Dio();
    final res = await dio.get(url);
    final hslRegex = RegExp("[\"']hls[\"']:\\s*[\"'](.*)[\"']");

    String? hslContent = hslRegex.firstMatch(res.data)?.group(1);
    if (hslContent == null) {
      final redirectMatch =
          RegExp(r"window\.location\.href = '([^']+)'").firstMatch(res.data);

      if (redirectMatch != null) {
        final redirectUrl = redirectMatch.group(1);
        if (redirectUrl != null) {
          final hlsMatch =
              hslRegex.firstMatch((await dio.get(redirectUrl)).data);
          hslContent = hlsMatch?.group(1);
        }
      }
    }

    if (hslContent == null) {
      throw const NoSourcesException();
    }

    return utf8.decoder.convert(base64Decode(hslContent));
  }

  static bool isSupported(final String url) {
    return [
      "voe.sx",
      "tubelessceliolymph.com",
      "simpulumlamerop.com",
      "urochsunloath.com",
      "yip.su",
      "metagnathtuggers.com",
      "donaldlineelse.com"
    ].any((final domain) => url.contains(domain));
  }
}

class BigWarpScraper extends VideoScraper {
  BigWarpScraper(super.url);

  @override
  Future<String> getVideoLink() async {
    final headers = {
      "user-agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
      "Sec-Fetch-Dest": "iframe",
      "referer": url.split("/").take(3).join("/")
    };

    for (int attempt = 0; attempt < 10; attempt++) {
      try {
        final response = await Dio().get(
          url,
          options: Options(
            headers: headers,
            followRedirects: true,
            validateStatus: (final status) => status != null && status < 500,
          ),
        );

        final document = parse(response.data);
        final scripts = document.getElementsByTagName("script");

        final script = scripts
            .map((final element) => element.text)
            .firstWhere(
              (final scriptContent) => scriptContent.contains("sources:"),
          orElse: () => "",
        );

        if (script.isEmpty) {
          await Future.delayed(const Duration(milliseconds: 500));
          continue;
        }

        final patterns = [
          r'sources:\s*\[\s*\{\s*file\s*:\s*"([^"]+)"',
          r'"file"\s*:\s*"([^"]+)"',
          r'file\s*:\s*"(https?://[^"]+\.(?:mp4|m3u8)[^"]*)"'
        ];

        for (final pattern in patterns) {
          final match = RegExp(pattern, dotAll: true).firstMatch(script);
          final fileUrl = match?.group(1);

          if (fileUrl != null && fileUrl.startsWith("http")) {
            return fileUrl;
          }
        }
      } catch (_) {}
    }

    throw Exception("Could not retrieve video link");
  }

  static bool isSupported(final String url) =>
      url.contains("bigwarp.io") || url.contains("bigwarp.art");
}

class LuluStreamScraper extends VideoScraper {
  LuluStreamScraper(super.url);

  @override
  Future<String> getVideoLink() async {
    final Dio dio = Dio();
    final headers = {
      "user-agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
      "referer": getBaseUrl(url),
      "accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
    };

    String? script;
    int attempts = 0;

    while (attempts < 10 && (script == null || script.isEmpty)) {
      attempts++;
      try {
        final response = await dio.get(
          url,
          options: Options(
            headers: headers,
            followRedirects: true,
            validateStatus: (final status) => status != null && status < 500,
          ),
        );

        final document = parse(response.data);
        final scripts = document.getElementsByTagName("script");

        for (final element in scripts) {
          final scriptContent = element.text.trim();
          if (scriptContent.contains("jwplayer") &&
              scriptContent.contains("setup")) {
            script = scriptContent;
            break;
          }
        }
      } catch (e) {
        throw Exception("Could not retrieve video link");
      }

      if (script == null || script.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }

    if (script == null || script.isEmpty) {
      throw Exception("Could not retrieve video link");
    }

    final String decodedScript = decodeEvalScript(script);

    try {
      final sourcesMatch = RegExp(r'sources:\s*\[\s*\{\s*file\s*:\s*"([^"]+)"')
          .firstMatch(decodedScript);
      String? fileUrl = sourcesMatch?.group(1);

      if (fileUrl == null || fileUrl.isEmpty) {
        final fileMatch = RegExp(r'"file"\s*:\s*"([^"]+)"').firstMatch(
            decodedScript);
        fileUrl = fileMatch?.group(1);
      }

      if (fileUrl == null || fileUrl.isEmpty) {
        final m3u8Match = RegExp(r'https?://[^\s"]+\.m3u8').firstMatch(
            decodedScript);
        fileUrl = m3u8Match?.group(0);
      }

      if (fileUrl == null || fileUrl.isEmpty) {
        throw Exception("Could not retrieve video link");
      }

      if (!fileUrl.startsWith("http")) {
        final baseUrl = getBaseUrl(url);
        fileUrl = "$baseUrl$fileUrl";

        if (!Uri
            .parse(fileUrl)
            .isAbsolute) {
          throw Exception("Could not retrieve video link");
        }
      }

      return fileUrl;
    } catch (_) {
      throw Exception("Could not retrieve video link");
    }
  }

  String decodeEvalScript(final String script) {
    if (!script.startsWith("eval")) return script;

    final evalMatch = RegExp(
        r"eval\(function\(p,a,c,k,e,d\)\{.*?\}\('(.*?)',(\d+),(\d+),'(.*?)'\.split")
        .firstMatch(script);
    if (evalMatch == null) return script;

    String p = evalMatch.group(1)!;
    final int a = int.parse(evalMatch.group(2)!);
    int c = int.parse(evalMatch.group(3)!);
    final List<String> k = evalMatch.group(4)!.split("|");

    while (c-- > 0) {
      if (k[c].isNotEmpty) {
        p = p.replaceAll(RegExp("\\b${c.toRadixString(a)}\\b"), k[c]);
      }
    }
    return p;
  }

  static bool isSupported(final String url) {
    return url.contains("lulustream.com") || url.contains("luluvdo.com");
  }
}

class VidmolyScraper extends VideoScraper {
  VidmolyScraper(super.url);

  @override
  Future<String> getVideoLink() async {
    final dio = Dio();
    final newUrl = url.contains("/w/")
        ? "${url.replaceFirst("/w/", "/embed-")}-920x360.html"
        : url;

    final headers = {
      "user-agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
      "Sec-Fetch-Dest": "iframe",
      "referer": getBaseUrl(url)
    };

    for (int attempts = 0; attempts < 10; attempts++) {
      try {
        final response = await dio.get(
          newUrl,
          options: Options(
            headers: headers,
            followRedirects: true,
            validateStatus: (final status) => status != null && status < 500,
          ),
        );

        final document = parse(response.data);
        final scripts = document.getElementsByTagName("script");

        for (final element in scripts) {
          final scriptContent = element.text;
          if (scriptContent.contains("sources:")) {
            final sourceMatch = RegExp(r'sources:\s*\[\s*\{\s*(?:.*?)file\s*:\s*"([^"]+)"').firstMatch(scriptContent);
            final directMatch = RegExp(r'"file"\s*:\s*"([^"]+)"').firstMatch(scriptContent);

            String? fileUrl;

            if (sourceMatch != null && sourceMatch.group(1) != null) {
              fileUrl = sourceMatch.group(1);
            } else if (directMatch != null && directMatch.group(1) != null) {
              fileUrl = directMatch.group(1);
            }

            if (fileUrl != null && fileUrl.startsWith("http")) {
              return fileUrl;
            }
          }
        }

        await Future.delayed(const Duration(milliseconds: 500));
      } catch (_) {}
    }

    throw const ();
  }

  static bool isSupported(final String url) {
    return url.contains("vidmoly.to") || url.contains("vidmoly.me");
  }
}

VideoScraper getScraper(final String url) {
  if (StreamtapeScraper.isSupported(url)) {
    return StreamtapeScraper(url);
  } else if (VidozaScraper.isSupported(url)) {
    return VidozaScraper(url);
  } else if (VtubeScraper.isSupported(url)) {
    return VtubeScraper(url);
  } else if (DoodStreamScraper.isSupported(url)) {
    return DoodStreamScraper(url);
  } else if (BigWarpScraper.isSupported(url)) {
    return BigWarpScraper(url);
  } else if (LuluStreamScraper.isSupported(url)) {
    return LuluStreamScraper(url);
  } else if (VidmolyScraper.isSupported(url)) {
    return VidmolyScraper(url);
  } else if (VoeScraper.isSupported(url)) {
    return VoeScraper(url);
  } else {
    throw Exception("Unsupported host: $url");
  }
}

class MediaLink {
  final String url;
  final Language language;
  final Quality quality;
  late final VideoScraper _scraper;

  String? _directVideoUrl;
  bool _isVideoValid = false;
  int _responseTime = 0;

  MediaLink(this.url, final String language, final String quality)
      : language = Language.values
            .firstWhere((final lang) => lang.language == language),
        quality =
            Quality.values.firstWhere((final qual) => qual.quality == quality),
        _scraper = getScraper(url);

  MediaLink.fromMap(final Map<String, dynamic> map)
      : url = map["url"] as String,
        language = Language.values
            .firstWhere((final lang) => lang.language == map["language"]),
        quality = Quality.values
            .firstWhere((final qual) => qual.quality == map["quality"]),
        _scraper = getScraper(map["url"] as String);

  Map<String, dynamic> toMap() {
    return {
      "url": url,
      "language": language.language,
      "quality": quality.quality,
    };
  }

  Future<String?> getDirectLink() async {
    if (_directVideoUrl != null) {
      return _directVideoUrl;
    }

    try {
      _directVideoUrl = await _scraper.getVideoLink();

      await verifyDirectVideoUrl();
    } catch (e) {
      _directVideoUrl = null;
      _isVideoValid = false;
    }

    return _directVideoUrl;
  }

  Future<void> verifyDirectVideoUrl() async {
    if (_directVideoUrl == null) return;

    try {
      final stopwatch = Stopwatch()..start();
      final response = await Dio().head(
        _directVideoUrl!,
        options: Options(
            followRedirects: true, headers: {"referer": getBaseUrl(url)}),
      );
      stopwatch.stop();
      debugPrint(response.headers.toString());
      _isVideoValid = response.statusCode == 200 &&
          (response.headers.value("content-type")?.contains("video") == true ||
              response.headers.value("content-type")?.contains("mpegurl") ==
                  true);
      _responseTime = stopwatch.elapsedMilliseconds;
    } catch (_) {
      _isVideoValid = false;
    }
  }

  bool get isVideoValid => _isVideoValid;
  int get responseTime => _responseTime;

  @override
  String toString() =>
      "MediaLink(url: $url, language: $language, quality: $quality, responseTime: $responseTime, directVideoUrl: $_directVideoUrl, isVideoValid: $_isVideoValid)";
}
