import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:test/test.dart';

import '_fixtures.dart';

/// Cross-product densification rules. Densification fills in cells
/// that don't appear in the observed data: synthetic empty cells with
/// typed-zero values for additive aggregations and `null` for
/// non-additive ones. Single-axis temporal queries extend their axis
/// via `dateRange`; multi-axis queries Cartesian-product the observed
/// keys on each non-temporal axis.
void main() {
  final tasks = tasksSource();
  final events = eventsSource();

  // ────────────────────────────────────────────────────────────────────
  // 1-D categorical: no synthetic cells
  // ────────────────────────────────────────────────────────────────────

  group('1-D categorical — no synthetic cells', () {
    test('single-axis categorical groupBy emits one cell per observed key', () {
      final records = [
        SourceRecord(fields: {'status': const EnumValue('todo')}),
        SourceRecord(fields: {'status': const EnumValue('done')}),
      ];
      final result = AnalyticsExecutor.execute(
        query: AnalyticsQuerySpec(
          source: 'tasks',
          measures: const [CountMeasure()],
          groupBys: [FieldGroupBy(fieldRef: ref('tasks', 'status'))],
        ),
        records: records,
        sources: [tasks],
      );
      final series = result.okOrNull as SeriesResult;
      // Two distinct keys → two cells, no densification.
      expect(series.buckets, hasLength(2));
      expect(series.buckets.map((b) => b.value).toList(), [
        const IntValue(1),
        const IntValue(1),
      ]);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // 1-D temporal: extension via dateRange
  // ────────────────────────────────────────────────────────────────────

  group('1-D temporal — dateRange fills missing days', () {
    test('every day in [start, endExclusive) appears as a cell', () {
      // Records on May 1, 3, 5. dateRange covers May 1..7 (May 6 last
      // observed day with endExclusive = May 7). Expected: 6 cells
      // for May 1..6 (May 2, 4, 6 are synthetic).
      final records = [
        SourceRecord(
          fields: {
            'occurredAt': DateTimeValue(DateTime(2026, 5, 1)),
            'amount': const IntValue(1),
          },
        ),
        SourceRecord(
          fields: {
            'occurredAt': DateTimeValue(DateTime(2026, 5, 3)),
            'amount': const IntValue(1),
          },
        ),
        SourceRecord(
          fields: {
            'occurredAt': DateTimeValue(DateTime(2026, 5, 5)),
            'amount': const IntValue(1),
          },
        ),
      ];
      final result = AnalyticsExecutor.execute(
        query: AnalyticsQuerySpec(
          source: 'events',
          measures: const [CountMeasure()],
          groupBys: [
            TimeGroupBy(
              dateFieldRef: ref('events', 'occurredAt'),
              grain: TimeGrain.day,
            ),
          ],
        ),
        records: records,
        sources: [events],
        dateRange: (DateTime(2026, 5, 1), DateTime(2026, 5, 7)),
      );
      final series = result.okOrNull as SeriesResult;
      expect(series.buckets, hasLength(6));
      // Synthetic-cell positions (May 2, 4, 6) carry IntValue(0).
      expect(series.buckets.map((b) => (b.value as IntValue).value).toList(), [
        1,
        0,
        1,
        0,
        1,
        0,
      ]);
    });

    test('without dateRange there are no synthetic cells', () {
      final records = [
        SourceRecord(
          fields: {
            'occurredAt': DateTimeValue(DateTime(2026, 5, 1)),
            'amount': const IntValue(1),
          },
        ),
        SourceRecord(
          fields: {
            'occurredAt': DateTimeValue(DateTime(2026, 5, 3)),
            'amount': const IntValue(1),
          },
        ),
      ];
      final result = AnalyticsExecutor.execute(
        query: AnalyticsQuerySpec(
          source: 'events',
          measures: const [CountMeasure()],
          groupBys: [
            TimeGroupBy(
              dateFieldRef: ref('events', 'occurredAt'),
              grain: TimeGrain.day,
            ),
          ],
        ),
        records: records,
        sources: [events],
      );
      final series = result.okOrNull as SeriesResult;
      expect(series.buckets, hasLength(2));
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Empty-cell values by aggregation kind
  // ────────────────────────────────────────────────────────────────────

  group('synthetic empty cells — additive aggregations use typed zero', () {
    final eventsWithDur = SourceDef(
      sourceId: 'events',
      displayName: 'Events',
      fields: const [
        FieldDef(
          sourceId: 'events',
          fieldId: 'occurredAt',
          displayName: 'Occurred At',
          fieldType: FieldType.dateTime,
          filterable: true,
          groupable: true,
          aggregatable: false,
          sortable: true,
        ),
        FieldDef(
          sourceId: 'events',
          fieldId: 'amountInt',
          displayName: 'Amount (int)',
          fieldType: FieldType.integer,
          filterable: true,
          groupable: false,
          aggregatable: true,
          sortable: true,
        ),
        FieldDef(
          sourceId: 'events',
          fieldId: 'amountDouble',
          displayName: 'Amount (double)',
          fieldType: FieldType.double,
          filterable: true,
          groupable: false,
          aggregatable: true,
          sortable: true,
        ),
        FieldDef(
          sourceId: 'events',
          fieldId: 'dur',
          displayName: 'Duration',
          fieldType: FieldType.duration,
          filterable: true,
          groupable: false,
          aggregatable: true,
          sortable: true,
        ),
      ],
      primaryDateFieldId: 'occurredAt',
    );

    /// One record on May 1; dateRange spans May 1..3 (so May 2 is
    /// synthetic).
    List<SourceRecord> singleObservation({
      int? amountInt,
      double? amountDouble,
      Duration? dur,
    }) => [
      SourceRecord(
        fields: {
          'occurredAt': DateTimeValue(DateTime(2026, 5, 1)),
          if (amountInt != null) 'amountInt': IntValue(amountInt),
          if (amountDouble != null) 'amountDouble': DoubleValue(amountDouble),
          if (dur != null) 'dur': DurationValue(dur),
        },
      ),
    ];

    TypedValue? secondBucketValue(SeriesResult s) => s.buckets[1].value;

    SeriesResult runSeries(Measure measure, List<SourceRecord> records) {
      return AnalyticsExecutor.execute(
            query: AnalyticsQuerySpec(
              source: 'events',
              measures: [measure],
              groupBys: [
                TimeGroupBy(
                  dateFieldRef: ref('events', 'occurredAt'),
                  grain: TimeGrain.day,
                ),
              ],
            ),
            records: records,
            sources: [eventsWithDur],
            dateRange: (DateTime(2026, 5, 1), DateTime(2026, 5, 3)),
          ).okOrNull
          as SeriesResult;
    }

    test('count returns IntValue(0) on empty cells', () {
      final s = runSeries(
        const CountMeasure(),
        singleObservation(amountInt: 1),
      );
      expect(secondBucketValue(s), const IntValue(0));
    });

    test('sum over integer returns IntValue(0)', () {
      final s = runSeries(
        FieldMeasure(
          fieldRef: ref('events', 'amountInt'),
          aggregation: const SumAgg(),
        ),
        singleObservation(amountInt: 5),
      );
      expect(secondBucketValue(s), const IntValue(0));
    });

    test('sum over double returns DoubleValue(0.0)', () {
      final s = runSeries(
        FieldMeasure(
          fieldRef: ref('events', 'amountDouble'),
          aggregation: const SumAgg(),
        ),
        singleObservation(amountDouble: 5.5),
      );
      expect(secondBucketValue(s), const DoubleValue(0.0));
    });

    test('sum over duration returns DurationValue(zero)', () {
      final s = runSeries(
        FieldMeasure(
          fieldRef: ref('events', 'dur'),
          aggregation: const SumAgg(),
        ),
        singleObservation(dur: const Duration(seconds: 1)),
      );
      expect(secondBucketValue(s), const DurationValue(Duration.zero));
    });

    test('distinctCount returns IntValue(0)', () {
      final s = runSeries(
        FieldMeasure(
          fieldRef: ref('events', 'amountInt'),
          aggregation: const DistinctCountAgg(),
        ),
        singleObservation(amountInt: 1),
      );
      expect(secondBucketValue(s), const IntValue(0));
    });
  });

  group('synthetic empty cells — non-additive aggregations return null', () {
    final eventsWithAmt = SourceDef(
      sourceId: 'events',
      displayName: 'Events',
      fields: const [
        FieldDef(
          sourceId: 'events',
          fieldId: 'occurredAt',
          displayName: 'Occurred At',
          fieldType: FieldType.dateTime,
          filterable: true,
          groupable: true,
          aggregatable: false,
          sortable: true,
        ),
        FieldDef(
          sourceId: 'events',
          fieldId: 'amount',
          displayName: 'Amount',
          fieldType: FieldType.integer,
          filterable: true,
          groupable: false,
          aggregatable: true,
          sortable: true,
        ),
      ],
      primaryDateFieldId: 'occurredAt',
    );

    SeriesResult runSeries(FieldAggregation agg) {
      final records = [
        SourceRecord(
          fields: {
            'occurredAt': DateTimeValue(DateTime(2026, 5, 1)),
            'amount': const IntValue(5),
          },
        ),
      ];
      return AnalyticsExecutor.execute(
            query: AnalyticsQuerySpec(
              source: 'events',
              measures: [
                FieldMeasure(
                  fieldRef: ref('events', 'amount'),
                  aggregation: agg,
                ),
              ],
              groupBys: [
                TimeGroupBy(
                  dateFieldRef: ref('events', 'occurredAt'),
                  grain: TimeGrain.day,
                ),
              ],
            ),
            records: records,
            sources: [eventsWithAmt],
            dateRange: (DateTime(2026, 5, 1), DateTime(2026, 5, 3)),
          ).okOrNull
          as SeriesResult;
    }

    test('average returns null', () {
      final s = runSeries(const AverageAgg());
      expect(s.buckets[1].value, isNull);
    });
    test('min returns null', () {
      final s = runSeries(const MinAgg());
      expect(s.buckets[1].value, isNull);
    });
    test('max returns null', () {
      final s = runSeries(const MaxAgg());
      expect(s.buckets[1].value, isNull);
    });
    test('percentile returns null', () {
      final s = runSeries(const PercentileAgg(p: 0.5));
      expect(s.buckets[1].value, isNull);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Cross-product over multiple axes
  // ────────────────────────────────────────────────────────────────────

  group('multi-axis cross-product densification', () {
    final twoAxisSource = SourceDef(
      sourceId: 'two',
      displayName: 'Two',
      fields: const [
        FieldDef(
          sourceId: 'two',
          fieldId: 'a',
          displayName: 'A',
          fieldType: FieldType.enumeration,
          filterable: true,
          groupable: true,
          aggregatable: false,
          sortable: true,
        ),
        FieldDef(
          sourceId: 'two',
          fieldId: 'b',
          displayName: 'B',
          fieldType: FieldType.enumeration,
          filterable: true,
          groupable: true,
          aggregatable: false,
          sortable: true,
        ),
      ],
    );

    test('2-D over keys (A,X) and (B,Y) produces 4-cell cross-product', () {
      final records = [
        SourceRecord(
          fields: {'a': const EnumValue('A'), 'b': const EnumValue('X')},
        ),
        SourceRecord(
          fields: {'a': const EnumValue('B'), 'b': const EnumValue('Y')},
        ),
      ];
      final result = AnalyticsExecutor.execute(
        query: AnalyticsQuerySpec(
          source: 'two',
          measures: const [CountMeasure()],
          groupBys: [
            FieldGroupBy(fieldRef: ref('two', 'a')),
            FieldGroupBy(fieldRef: ref('two', 'b')),
          ],
        ),
        records: records,
        sources: [twoAxisSource],
      );
      final ms = result.okOrNull as MultiSeriesResult;
      // 2 primary positions (A, B) × 2 secondary positions (X, Y) = 4 cells.
      expect(ms.xAxis, hasLength(2));
      expect(ms.series, hasLength(2));
      // Total cells across all series: 4.
      final allCells = [for (final s in ms.series) ...s.values];
      expect(allCells, hasLength(4));
      // (A,X) and (B,Y) are observed → IntValue(1). The other two
      // are synthetic → IntValue(0).
      final ones = allCells.where((v) => v == const IntValue(1)).length;
      final zeros = allCells.where((v) => v == const IntValue(0)).length;
      expect(ones, 2);
      expect(zeros, 2);
    });

    test('3-D groupBys produce a full Cartesian-product table', () {
      final threeAxis = SourceDef(
        sourceId: 'three',
        displayName: 'Three',
        fields: const [
          FieldDef(
            sourceId: 'three',
            fieldId: 'a',
            displayName: 'A',
            fieldType: FieldType.enumeration,
            filterable: true,
            groupable: true,
            aggregatable: false,
            sortable: true,
          ),
          FieldDef(
            sourceId: 'three',
            fieldId: 'b',
            displayName: 'B',
            fieldType: FieldType.enumeration,
            filterable: true,
            groupable: true,
            aggregatable: false,
            sortable: true,
          ),
          FieldDef(
            sourceId: 'three',
            fieldId: 'c',
            displayName: 'C',
            fieldType: FieldType.enumeration,
            filterable: true,
            groupable: true,
            aggregatable: false,
            sortable: true,
          ),
        ],
      );
      final records = [
        SourceRecord(
          fields: {
            'a': const EnumValue('A1'),
            'b': const EnumValue('B1'),
            'c': const EnumValue('C1'),
          },
        ),
        SourceRecord(
          fields: {
            'a': const EnumValue('A2'),
            'b': const EnumValue('B2'),
            'c': const EnumValue('C2'),
          },
        ),
      ];
      final result = AnalyticsExecutor.execute(
        query: AnalyticsQuerySpec(
          source: 'three',
          measures: const [CountMeasure()],
          groupBys: [
            FieldGroupBy(fieldRef: ref('three', 'a')),
            FieldGroupBy(fieldRef: ref('three', 'b')),
            FieldGroupBy(fieldRef: ref('three', 'c')),
          ],
        ),
        records: records,
        sources: [threeAxis],
      );
      final table = result.okOrNull as TableResult;
      // 2 × 2 × 2 = 8 cells in the cross-product.
      expect(table.rowCount, 8);
      // Row keys are length-3 tuples.
      for (final rk in table.rowKeys) {
        expect(rk.keys, hasLength(3));
      }
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Ordering: outermost axis is groupBys[0]
  // ────────────────────────────────────────────────────────────────────

  group('densified cell ordering follows BucketKeyOrdering per axis', () {
    test('outer loop is groupBys[0], inner loop is the last groupBy', () {
      final two = SourceDef(
        sourceId: 'two',
        displayName: 'Two',
        fields: const [
          FieldDef(
            sourceId: 'two',
            fieldId: 'a',
            displayName: 'A',
            fieldType: FieldType.enumeration,
            filterable: true,
            groupable: true,
            aggregatable: false,
            sortable: true,
          ),
          FieldDef(
            sourceId: 'two',
            fieldId: 'b',
            displayName: 'B',
            fieldType: FieldType.enumeration,
            filterable: true,
            groupable: true,
            aggregatable: false,
            sortable: true,
          ),
        ],
      );
      final records = [
        SourceRecord(
          fields: {'a': const EnumValue('alpha'), 'b': const EnumValue('x')},
        ),
        SourceRecord(
          fields: {'a': const EnumValue('beta'), 'b': const EnumValue('y')},
        ),
      ];
      final result = AnalyticsExecutor.execute(
        query: AnalyticsQuerySpec(
          source: 'two',
          measures: const [CountMeasure()],
          groupBys: [
            FieldGroupBy(fieldRef: ref('two', 'a')),
            FieldGroupBy(fieldRef: ref('two', 'b')),
          ],
        ),
        records: records,
        sources: [two],
      );
      final ms = result.okOrNull as MultiSeriesResult;
      // X-axis (primary, axis 0) is sorted: alpha, beta.
      expect(ms.xAxis.map((p) => p.key).toList(), [
        const EnumBucketKey('alpha'),
        const EnumBucketKey('beta'),
      ]);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // Synthetic-cell tracking
  // ────────────────────────────────────────────────────────────────────

  group(
    'synthetic-cell tracking — densified cells carry isSynthetic markers',
    () {
      // The executor distinguishes observed cells (at least one record
      // landed in the bucket) from synthetic cells (densification filled
      // in a missing cross-product combination or extended the temporal
      // axis). Consumers — CSV exporters, renderers that want different
      // visuals for "no data" vs "real zero" — rely on these markers.

      test('SeriesResult marks synthetic temporal buckets', () {
        // Records on May 1 and May 3 only; densification fills May 2 as
        // synthetic.
        final records = [
          SourceRecord(
            fields: {
              'occurredAt': DateTimeValue(DateTime(2026, 5, 1)),
              'amount': const IntValue(1),
            },
          ),
          SourceRecord(
            fields: {
              'occurredAt': DateTimeValue(DateTime(2026, 5, 3)),
              'amount': const IntValue(1),
            },
          ),
        ];
        final s =
            AnalyticsExecutor.execute(
                  query: AnalyticsQuerySpec(
                    source: 'events',
                    measures: const [CountMeasure()],
                    groupBys: [
                      TimeGroupBy(
                        dateFieldRef: ref('events', 'occurredAt'),
                        grain: TimeGrain.day,
                      ),
                    ],
                  ),
                  records: records,
                  sources: [events],
                  dateRange: (DateTime(2026, 5, 1), DateTime(2026, 5, 4)),
                ).okOrNull
                as SeriesResult;

        // 3 buckets: May 1 (observed), May 2 (synthetic), May 3 (observed).
        expect(s.buckets.map((b) => b.isSynthetic).toList(), [
          false,
          true,
          false,
        ]);
      });

      test('MultiSeriesResult marks synthetic positions per NamedSeries', () {
        // (A, X) and (B, Y) observed; (A, Y) and (B, X) synthesized by
        // the 2×2 cross product.
        final twoAxis = SourceDef(
          sourceId: 'two',
          displayName: 'Two',
          fields: const [
            FieldDef(
              sourceId: 'two',
              fieldId: 'a',
              displayName: 'A',
              fieldType: FieldType.enumeration,
              filterable: true,
              groupable: true,
              aggregatable: false,
              sortable: true,
            ),
            FieldDef(
              sourceId: 'two',
              fieldId: 'b',
              displayName: 'B',
              fieldType: FieldType.enumeration,
              filterable: true,
              groupable: true,
              aggregatable: false,
              sortable: true,
            ),
          ],
        );
        final records = [
          SourceRecord(
            fields: {'a': const EnumValue('A'), 'b': const EnumValue('X')},
          ),
          SourceRecord(
            fields: {'a': const EnumValue('B'), 'b': const EnumValue('Y')},
          ),
        ];
        final ms =
            AnalyticsExecutor.execute(
                  query: AnalyticsQuerySpec(
                    source: 'two',
                    measures: const [CountMeasure()],
                    groupBys: [
                      FieldGroupBy(fieldRef: ref('two', 'a')),
                      FieldGroupBy(fieldRef: ref('two', 'b')),
                    ],
                  ),
                  records: records,
                  sources: [twoAxis],
                ).okOrNull
                as MultiSeriesResult;

        // xAxis sorted: A, B. Series sorted (encounter, then secondary
        // sort): X, Y. Two synthetic positions across the two series.
        final totalSynthetic = ms.series.fold<int>(
          0,
          (n, s) => n + s.syntheticValueIndices.length,
        );
        expect(totalSynthetic, 2);
      });

      test('MultiMeasureSeriesResult marks synthetic x-axis positions', () {
        // Records on May 1 only; May 2 in date range → synthetic position.
        final records = [
          SourceRecord(
            fields: {
              'occurredAt': DateTimeValue(DateTime(2026, 5, 1)),
              'amount': const IntValue(10),
            },
          ),
        ];
        final mm =
            AnalyticsExecutor.execute(
                  query: AnalyticsQuerySpec(
                    source: 'events',
                    measures: [
                      const CountMeasure(label: 'n'),
                      FieldMeasure(
                        fieldRef: ref('events', 'amount'),
                        aggregation: const SumAgg(),
                        label: 'total',
                      ),
                    ],
                    groupBys: [
                      TimeGroupBy(
                        dateFieldRef: ref('events', 'occurredAt'),
                        grain: TimeGrain.day,
                      ),
                    ],
                  ),
                  records: records,
                  sources: [events],
                  dateRange: (DateTime(2026, 5, 1), DateTime(2026, 5, 3)),
                ).okOrNull
                as MultiMeasureSeriesResult;

        // x-axis has 2 positions: May 1 (observed, idx 0), May 2
        // (synthetic, idx 1).
        expect(mm.syntheticXAxisIndices, {1});
      });

      test('TableResult marks synthetic rows for densified cells', () {
        // 0-groupBy multi-measure has a single observed row → no
        // synthetic rows.
        final zeroGroup =
            AnalyticsExecutor.execute(
                  query: AnalyticsQuerySpec(
                    source: 'tasks',
                    measures: const [
                      CountMeasure(label: 'a'),
                      CountMeasure(label: 'b'),
                    ],
                  ),
                  records: [
                    SourceRecord(fields: {'status': const EnumValue('todo')}),
                  ],
                  sources: [tasks],
                ).okOrNull
                as TableResult;
        expect(zeroGroup.syntheticRowIndices, isEmpty);

        // 3-groupBy table with sparse data → most cells synthetic.
        final threeAxis = SourceDef(
          sourceId: 'three',
          displayName: 'Three',
          fields: const [
            FieldDef(
              sourceId: 'three',
              fieldId: 'a',
              displayName: 'A',
              fieldType: FieldType.enumeration,
              filterable: true,
              groupable: true,
              aggregatable: false,
              sortable: true,
            ),
            FieldDef(
              sourceId: 'three',
              fieldId: 'b',
              displayName: 'B',
              fieldType: FieldType.enumeration,
              filterable: true,
              groupable: true,
              aggregatable: false,
              sortable: true,
            ),
            FieldDef(
              sourceId: 'three',
              fieldId: 'c',
              displayName: 'C',
              fieldType: FieldType.enumeration,
              filterable: true,
              groupable: true,
              aggregatable: false,
              sortable: true,
            ),
          ],
        );
        final table =
            AnalyticsExecutor.execute(
                  query: AnalyticsQuerySpec(
                    source: 'three',
                    measures: const [CountMeasure()],
                    groupBys: [
                      FieldGroupBy(fieldRef: ref('three', 'a')),
                      FieldGroupBy(fieldRef: ref('three', 'b')),
                      FieldGroupBy(fieldRef: ref('three', 'c')),
                    ],
                  ),
                  records: [
                    SourceRecord(
                      fields: {
                        'a': const EnumValue('A1'),
                        'b': const EnumValue('B1'),
                        'c': const EnumValue('C1'),
                      },
                    ),
                    SourceRecord(
                      fields: {
                        'a': const EnumValue('A2'),
                        'b': const EnumValue('B2'),
                        'c': const EnumValue('C2'),
                      },
                    ),
                  ],
                  sources: [threeAxis],
                ).okOrNull
                as TableResult;
        // 2×2×2 = 8 rows; 2 observed → 6 synthetic.
        expect(table.syntheticRowIndices, hasLength(6));
      });
    },
  );

  // ────────────────────────────────────────────────────────────────────
  // densify: false — observed cells only, no synthetic markers
  // ────────────────────────────────────────────────────────────────────

  group('densify: false — produces observed cells only', () {
    test('temporal axis is not extended via dateRange', () {
      // Records on May 1 and May 3; without densification the gap on
      // May 2 is not filled.
      final records = [
        SourceRecord(
          fields: {
            'occurredAt': DateTimeValue(DateTime(2026, 5, 1)),
            'amount': const IntValue(1),
          },
        ),
        SourceRecord(
          fields: {
            'occurredAt': DateTimeValue(DateTime(2026, 5, 3)),
            'amount': const IntValue(1),
          },
        ),
      ];
      final s =
          AnalyticsExecutor.execute(
                query: AnalyticsQuerySpec(
                  source: 'events',
                  measures: const [CountMeasure()],
                  groupBys: [
                    TimeGroupBy(
                      dateFieldRef: ref('events', 'occurredAt'),
                      grain: TimeGrain.day,
                    ),
                  ],
                ),
                records: records,
                sources: [events],
                dateRange: (DateTime(2026, 5, 1), DateTime(2026, 5, 4)),
                densify: false,
              ).okOrNull
              as SeriesResult;

      // Two buckets — only the observed days. Neither is synthetic.
      expect(s.buckets, hasLength(2));
      expect(s.buckets.every((b) => !b.isSynthetic), isTrue);
    });

    test('multi-axis cross-product is not materialized', () {
      // (A, X) and (B, Y) only; without densification the missing
      // (A, Y) and (B, X) cells are not synthesized.
      final twoAxis = SourceDef(
        sourceId: 'two',
        displayName: 'Two',
        fields: const [
          FieldDef(
            sourceId: 'two',
            fieldId: 'a',
            displayName: 'A',
            fieldType: FieldType.enumeration,
            filterable: true,
            groupable: true,
            aggregatable: false,
            sortable: true,
          ),
          FieldDef(
            sourceId: 'two',
            fieldId: 'b',
            displayName: 'B',
            fieldType: FieldType.enumeration,
            filterable: true,
            groupable: true,
            aggregatable: false,
            sortable: true,
          ),
        ],
      );
      final records = [
        SourceRecord(
          fields: {'a': const EnumValue('A'), 'b': const EnumValue('X')},
        ),
        SourceRecord(
          fields: {'a': const EnumValue('B'), 'b': const EnumValue('Y')},
        ),
      ];
      final ms =
          AnalyticsExecutor.execute(
                query: AnalyticsQuerySpec(
                  source: 'two',
                  measures: const [CountMeasure()],
                  groupBys: [
                    FieldGroupBy(fieldRef: ref('two', 'a')),
                    FieldGroupBy(fieldRef: ref('two', 'b')),
                  ],
                ),
                records: records,
                sources: [twoAxis],
                densify: false,
              ).okOrNull
              as MultiSeriesResult;

      // Sparse: total cells across all series equals observed count (2).
      final totalCells = ms.series.fold<int>(
        0,
        (n, s) => n + s.values.where((v) => v != null).length,
      );
      // Every series carries an empty syntheticValueIndices.
      for (final s in ms.series) {
        expect(s.syntheticValueIndices, isEmpty);
      }
      // Total non-null cells: 2 observed.
      expect(totalCells, 2);
    });

    test('TableResult.syntheticRowIndices is empty when densify is false', () {
      final twoAxis = SourceDef(
        sourceId: 'two',
        displayName: 'Two',
        fields: const [
          FieldDef(
            sourceId: 'two',
            fieldId: 'a',
            displayName: 'A',
            fieldType: FieldType.enumeration,
            filterable: true,
            groupable: true,
            aggregatable: false,
            sortable: true,
          ),
          FieldDef(
            sourceId: 'two',
            fieldId: 'b',
            displayName: 'B',
            fieldType: FieldType.enumeration,
            filterable: true,
            groupable: true,
            aggregatable: false,
            sortable: true,
          ),
        ],
      );
      final table =
          AnalyticsExecutor.execute(
                query: AnalyticsQuerySpec(
                  source: 'two',
                  measures: const [
                    CountMeasure(label: 'a_count'),
                    CountMeasure(label: 'b_count'),
                  ],
                  groupBys: [
                    FieldGroupBy(fieldRef: ref('two', 'a')),
                    FieldGroupBy(fieldRef: ref('two', 'b')),
                  ],
                ),
                records: [
                  SourceRecord(
                    fields: {
                      'a': const EnumValue('A'),
                      'b': const EnumValue('X'),
                    },
                  ),
                ],
                sources: [twoAxis],
                densify: false,
              ).okOrNull
              as TableResult;

      // One observed cell → one row, not marked synthetic.
      expect(table.rowCount, 1);
      expect(table.syntheticRowIndices, isEmpty);
    });
  });
}
