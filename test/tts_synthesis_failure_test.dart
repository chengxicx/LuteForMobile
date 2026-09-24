// Regression guard for the one thing that broke read-aloud on the device:
// how the client tells "the server cannot voice this fragment, skip it" apart
// from "the server is broken, tell the user".
//
// History: the server used to answer `502 + {"error":"tts synthesis failed"}`
// and EdgeTTSService sniffed for that JSON marker. That works only until the
// response goes through a proxy that rewrites 5xx bodies -- Cloudflare answers
// origin 502s with its own `error code: 502` page, so the marker never arrived,
// the client rethrew a generic HTTP error, and the reader showed a raw Dio
// message and stalled on the fragment. The server now answers 422, which is a
// 4xx and therefore passes through untouched. These tests pin both halves of
// that contract.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lute_for_mobile/core/network/tts_service.dart';

Response<dynamic> _response(int status, Object? body) => Response<dynamic>(
  requestOptions: RequestOptions(path: '/tts/ja-JP/%E3%80%8D'),
  statusCode: status,
  data: body,
);

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

const _markerBody = '{"error":"tts synthesis failed"}\n';

/// What Cloudflare returns in place of an origin 502 body.
const _cloudflareBody = 'error code: 502\n';

void main() {
  group('EdgeTTSService.isSynthesisFailureResponse', () {
    test('422 is the fragment signal', () {
      expect(
        EdgeTTSService.isSynthesisFailureResponse(
          _response(422, _bytes(_markerBody)),
        ),
        isTrue,
      );
    });

    test('422 is trusted from its status alone', () {
      // A proxy is free to rewrite the body; the status code is the channel
      // that survives, so the body must not be required.
      expect(
        EdgeTTSService.isSynthesisFailureResponse(
          _response(422, _bytes(_cloudflareBody)),
        ),
        isTrue,
      );
      expect(
        EdgeTTSService.isSynthesisFailureResponse(_response(422, null)),
        isTrue,
      );
    });

    test('502 with the legacy marker still counts', () {
      // Keeps a new client usable against a server that has not been updated.
      expect(
        EdgeTTSService.isSynthesisFailureResponse(
          _response(502, _bytes(_markerBody)),
        ),
        isTrue,
      );
      expect(
        EdgeTTSService.isSynthesisFailureResponse(
          _response(502, _markerBody),
        ),
        isTrue,
      );
    });

    test('an opaque 502 stays a real error', () {
      // This is the case that used to hide the fix's purpose: through
      // Cloudflare a fragment's 502 arrived with a substituted body, and the
      // old code silently treated the missing marker as "real server error".
      // It must be an error -- the server answers 422 for skippable text, so
      // an unexplained 502 means something else is actually wrong.
      expect(
        EdgeTTSService.isSynthesisFailureResponse(
          _response(502, _bytes(_cloudflareBody)),
        ),
        isFalse,
      );
      expect(
        EdgeTTSService.isSynthesisFailureResponse(_response(502, null)),
        isFalse,
      );
    });

    test('unrelated statuses are not fragment signals', () {
      for (final status in [200, 401, 404, 500, 503]) {
        expect(
          EdgeTTSService.isSynthesisFailureResponse(
            _response(status, _bytes(_markerBody)),
          ),
          isFalse,
          reason: 'status $status must not be treated as a skippable fragment',
        );
      }
      expect(EdgeTTSService.isSynthesisFailureResponse(null), isFalse);
    });
  });
}
