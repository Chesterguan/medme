import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/screens/import_helpers.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';

/// Builds an [ImportOutcomeDto] with sane defaults, overriding only what a
/// given test cares about. Mirrors the shape `pipeline::ingest_pdf` actually
/// returns (see `apps/mobile_flutter/rust/src/api/dto.rs`).
ImportOutcomeDto _outcome({
  String status = 'new',
  List<int> pagesWithoutText = const [],
}) => ImportOutcomeDto(
  name: 'report.pdf',
  sourceFileId: 1,
  status: status,
  docType: 'lab_report',
  documentId: 1,
  detectedName: null,
  pagesWithoutText: Int32List.fromList(pagesWithoutText),
);

void main() {
  group('rowForOutcome', () {
    test(
      'falls back to rowFromOutcome when no pages were missing (the common case)',
      () {
        final outcome = _outcome(status: 'new');
        final row = rowForOutcome(outcome);
        expect(row.kind, ImportRowKind.success);
        expect(row.statusLabel, rowFromOutcome(outcome).statusLabel);
      },
    );

    test(
      'reports success when every missing page got backfilled on-device',
      () {
        final outcome = _outcome(status: 'new', pagesWithoutText: [2, 3]);
        final row = rowForOutcome(outcome, stillMissingPages: 0);
        expect(row.kind, ImportRowKind.success);
        expect(row.statusLabel, contains('OCR 补全'));
      },
    );

    test('reports partial -- not silently success -- when some pages remain '
        'unrecognized after best-effort backfill, and the document already '
        'has real content (mixed-page PDF: page 1 had a text layer)', () {
      final outcome = _outcome(status: 'new', pagesWithoutText: [2, 3]);
      final row = rowForOutcome(outcome, stillMissingPages: 1);
      expect(
        row.kind,
        ImportRowKind.partial,
        reason:
            'must not collapse to success -- the whole point of this '
            'field is telling the user something is still missing',
      );
      expect(row.statusLabel, contains('1'));
    });

    test(
      'reports storedNoText (not partial) when nothing was ever recovered '
      'for any page -- a fully scanned PDF where on-device OCR also failed',
      () {
        final outcome = _outcome(
          status: 'stored_no_text',
          pagesWithoutText: [1, 2, 3],
        );
        final row = rowForOutcome(outcome, stillMissingPages: 3);
        expect(row.kind, ImportRowKind.storedNoText);
        expect(row.statusLabel, contains('3'));
      },
    );

    test(
      'reports partial (not storedNoText) when the pipeline status was '
      "stored_no_text but on-device backfill recovered at least one page",
      () {
        final outcome = _outcome(
          status: 'stored_no_text',
          pagesWithoutText: [1, 2, 3],
        );
        // 1 of 3 originally-missing pages got recovered by on-device OCR.
        final row = rowForOutcome(outcome, stillMissingPages: 2);
        expect(
          row.kind,
          ImportRowKind.partial,
          reason: 'the document does have some real text now, not none',
        );
      },
    );
  });
}
