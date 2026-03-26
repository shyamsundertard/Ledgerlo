import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:isar/isar.dart';
import 'package:ledger_app/core/enums/transaction_type.dart';
import 'package:ledger_app/data/models/app_metadata.dart';
import 'package:ledger_app/data/models/business_profile.dart';
import 'package:ledger_app/data/models/customer.dart';
import 'package:ledger_app/data/models/transaction.dart' as txn_model;
import 'package:ledger_app/providers/currency_provider.dart';
import 'package:ledger_app/providers/settings_provider.dart';
import 'package:ledger_app/utils/transaction_labels.dart';

class AnalyticsScreen extends ConsumerStatefulWidget {
  final Isar isar;
  const AnalyticsScreen({super.key, required this.isar});

  @override
  ConsumerState<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

enum _RangePreset {
  days7('7D', 7),
  days30('30D', 30),
  days90('90D', 90),
  all('All', null);

  const _RangePreset(this.label, this.days);
  final String label;
  final int? days;
}

class _AnalyticsScreenState extends ConsumerState<AnalyticsScreen> {
  static const String _activeProfileKey = 'active_profile_id';

  _RangePreset _selectedRange = _RangePreset.all;
  late Future<_AnalyticsSnapshot> _snapshotFuture;

  @override
  void initState() {
    super.initState();
    _snapshotFuture = _loadAnalytics();
  }

  Future<void> _reload() async {
    setState(() {
      _snapshotFuture = _loadAnalytics();
    });
    await _snapshotFuture;
  }

  Future<_AnalyticsSnapshot> _loadAnalytics() async {
    final activeMetadata = await widget.isar.appMetadatas
        .filter()
        .keyEqualTo(_activeProfileKey)
        .findFirst();
    int? activeProfileId = int.tryParse(activeMetadata?.value ?? '');

    BusinessProfile? profile;
    if (activeProfileId != null) {
      profile = await widget.isar.businessProfiles.get(activeProfileId);
    }

    profile ??= await widget.isar.businessProfiles.where().findFirst();
    activeProfileId = profile?.id;

    if (activeProfileId == null) {
      return _AnalyticsSnapshot.empty();
    }

    final customers = await widget.isar.customers
      .filter()
      .profileIdEqualTo(activeProfileId)
      .findAll();

    final activeCustomers = customers
      .where((customer) => !customer.isDeleted)
      .toList();
    final activeCustomerIds = activeCustomers
      .map((customer) => customer.id)
      .toSet();
    final activeCustomerCount = activeCustomers.length;

    final activeTransactions = await widget.isar.transactions
        .filter()
        .profileIdEqualTo(activeProfileId)
      .isDeletedEqualTo(false)
        .findAll();
    final filteredActiveTransactions = activeTransactions
      .where((transaction) => activeCustomerIds.contains(transaction.customerId))
      .toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    final now = DateTime.now();
    final startDate = _selectedRange.days == null
        ? null
        : DateTime(
            now.year,
            now.month,
            now.day,
          ).subtract(Duration(days: _selectedRange.days! - 1));

    final rangeTransactions = startDate == null
      ? filteredActiveTransactions
      : filteredActiveTransactions
              .where((transaction) => !transaction.date.isBefore(startDate))
              .toList();

    final customersById = <int, Customer>{for (final c in customers) c.id: c};

    final customerBalances = <int, double>{};
    for (final transaction in filteredActiveTransactions) {
      final currentBalance = customerBalances[transaction.customerId] ?? 0;
      final delta = transaction.type == TransactionType.credit
          ? transaction.amount
          : -transaction.amount;
      customerBalances[transaction.customerId] = currentBalance + delta;
    }

    final totals = _RangeTotals.fromTransactions(rangeTransactions);
    final deletedTransactions = await widget.isar.transactions
      .filter()
      .profileIdEqualTo(activeProfileId)
      .isDeletedEqualTo(true)
      .findAll();

    final deletedTransactionCount = deletedTransactions
        .where(
          (transaction) =>
              activeCustomerIds.contains(transaction.customerId) &&
              (startDate == null || !transaction.date.isBefore(startDate)),
        )
        .length;

    final topCustomers = _topCustomers(
      transactions: rangeTransactions,
      customersById: customersById,
      activeCustomerIds: activeCustomerIds,
      limit: 5,
    );

    final dailySeries = _dailyNetSeries(rangeTransactions, startDate);

    double dueAmount = 0;
    double advanceAmount = 0;
    int dueCustomers = 0;
    int advanceCustomers = 0;

    for (final entry in customerBalances.entries) {
      final customer = customersById[entry.key];
      if (customer == null || customer.isDeleted) continue;
      if (entry.value < 0) {
        dueAmount += entry.value.abs();
        dueCustomers += 1;
      } else if (entry.value > 0) {
        advanceAmount += entry.value;
        advanceCustomers += 1;
      }
    }

    return _AnalyticsSnapshot(
      profileName: profile?.name ?? 'Business',
      activeCustomerCount: activeCustomerCount,
      totalCustomerCount: customers.length,
      deletedTransactionCount: deletedTransactionCount,
      rangeTransactionsCount: rangeTransactions.length,
      photoAttachmentCount: rangeTransactions
          .where(
            (transaction) =>
                transaction.photoPaths.any((path) => path.trim().isNotEmpty) ||
                (transaction.photoPath ?? '').trim().isNotEmpty,
          )
          .length,
      totals: totals,
      dueAmount: dueAmount,
      advanceAmount: advanceAmount,
      dueCustomers: dueCustomers,
      advanceCustomers: advanceCustomers,
      topCustomers: topCustomers,
      dailyNetSeries: dailySeries,
      startDate: startDate,
      endDate: now,
    );
  }

  List<_TopCustomerItem> _topCustomers({
    required List<txn_model.Transaction> transactions,
    required Map<int, Customer> customersById,
    required Set<int> activeCustomerIds,
    required int limit,
  }) {
    final totalsByCustomer = <int, double>{};
    final countsByCustomer = <int, int>{};
    for (final transaction in transactions) {
      if (!activeCustomerIds.contains(transaction.customerId)) continue;
      totalsByCustomer.update(
        transaction.customerId,
        (value) => value + transaction.amount,
        ifAbsent: () => transaction.amount,
      );
      countsByCustomer.update(
        transaction.customerId,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    }

    final items = totalsByCustomer.entries.map((entry) {
      final customer = customersById[entry.key];
      return _TopCustomerItem(
        name: customer?.name ?? 'Customer #${entry.key}',
        totalAmount: entry.value,
        transactionCount: countsByCustomer[entry.key] ?? 0,
      );
    }).toList()..sort((a, b) => b.totalAmount.compareTo(a.totalAmount));

    if (items.length <= limit) {
      return items;
    }
    return items.sublist(0, limit);
  }

  List<_DailyNetPoint> _dailyNetSeries(
    List<txn_model.Transaction> transactions,
    DateTime? startDate,
  ) {
    if (transactions.isEmpty) return [];

    final Map<DateTime, double> netByDay = {};
    for (final transaction in transactions) {
      final day = DateTime(
        transaction.date.year,
        transaction.date.month,
        transaction.date.day,
      );
      final delta = transaction.type == TransactionType.credit
          ? transaction.amount
          : -transaction.amount;
      netByDay.update(day, (value) => value + delta, ifAbsent: () => delta);
    }

    final sortedDays = netByDay.keys.toList()..sort();
    final firstDay = startDate != null && startDate.isBefore(sortedDays.first)
        ? startDate
        : sortedDays.first;

    final points = <_DailyNetPoint>[];
    for (var i = 0; i < sortedDays.length; i++) {
      final day = sortedDays[i];
      points.add(
        _DailyNetPoint(
          day: day,
          dayOffset: day.difference(firstDay).inDays.toDouble(),
          netAmount: netByDay[day] ?? 0,
        ),
      );
    }
    return points;
  }

  String _formatCurrency(double amount, String currencyCode) {
    final decimalDigits = amount == amount.roundToDouble() ? 0 : 2;
    return NumberFormat.simpleCurrency(
      name: currencyCode,
      decimalDigits: decimalDigits,
    ).format(amount);
  }

  @override
  Widget build(BuildContext context) {
    final currencyCode = ref.watch(currencyProvider);
    final labelStyle = ref.watch(settingsProvider);
    final creditLabel = getTransactionLabel(labelStyle, true);
    final debitLabel = getTransactionLabel(labelStyle, false);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Analytics'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<_AnalyticsSnapshot>(
        future: _snapshotFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  'Failed to load analytics\n${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final analytics = snapshot.data ?? _AnalyticsSnapshot.empty();
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          analytics.profileName,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _RangePreset.values.map((range) {
                            return ChoiceChip(
                              label: Text(range.label),
                              selected: _selectedRange == range,
                              onSelected: (selected) {
                                if (!selected || _selectedRange == range) {
                                  return;
                                }
                                setState(() {
                                  _selectedRange = range;
                                  _snapshotFuture = _loadAnalytics();
                                });
                              },
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          analytics.dateRangeLabel,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                _MetricGrid(
                  items: [
                    _MetricItem(
                      title: 'Net',
                      value: _formatCurrency(
                        analytics.totals.net,
                        currencyCode,
                      ),
                      icon: Icons.account_balance_wallet_outlined,
                    ),
                    _MetricItem(
                      title: creditLabel,
                      value: _formatCurrency(
                        analytics.totals.totalCredit,
                        currencyCode,
                      ),
                      icon: Icons.arrow_downward,
                    ),
                    _MetricItem(
                      title: debitLabel,
                      value: _formatCurrency(
                        analytics.totals.totalDebit,
                        currencyCode,
                      ),
                      icon: Icons.arrow_upward,
                    ),
                    _MetricItem(
                      title: 'Transactions',
                      value: analytics.rangeTransactionsCount.toString(),
                      icon: Icons.receipt_long_outlined,
                    ),
                    _MetricItem(
                      title: 'Avg Ticket',
                      value: _formatCurrency(
                        analytics.totals.averageTicket,
                        currencyCode,
                      ),
                      icon: Icons.auto_graph_outlined,
                    ),
                    _MetricItem(
                      title: 'Max Txn',
                      value: _formatCurrency(
                        analytics.totals.maxTransaction,
                        currencyCode,
                      ),
                      icon: Icons.trending_up,
                    ),
                    _MetricItem(
                      title: 'With Bills',
                      value: analytics.photoAttachmentCount.toString(),
                      icon: Icons.photo_camera_outlined,
                    ),
                    _MetricItem(
                      title: 'Deleted Txns',
                      value: analytics.deletedTransactionCount.toString(),
                      icon: Icons.delete_outline,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Receivables Snapshot',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: _InlineStat(
                                label: 'Due Customers',
                                value:
                                    '${analytics.dueCustomers} • ${_formatCurrency(analytics.dueAmount, currencyCode)}',
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _InlineStat(
                                label: 'Advance Customers',
                                value:
                                    '${analytics.advanceCustomers} • ${_formatCurrency(analytics.advanceAmount, currencyCode)}',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        _InlineStat(
                          label: 'Customers (active/total)',
                          value:
                              '${analytics.activeCustomerCount}/${analytics.totalCustomerCount}',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                _CashflowPieCard(
                  credit: analytics.totals.totalCredit,
                  debit: analytics.totals.totalDebit,
                  creditLabel: creditLabel,
                  debitLabel: debitLabel,
                  formatter: (amount) => _formatCurrency(amount, currencyCode),
                ),
                const SizedBox(height: 10),
                _DailyNetCard(
                  points: analytics.dailyNetSeries,
                  formatter: (amount) => _formatCurrency(amount, currencyCode),
                ),
                const SizedBox(height: 10),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Top Customers (by volume)',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 10),
                        if (analytics.topCustomers.isEmpty)
                          const Text('No customer activity in selected range.')
                        else
                          ...analytics.topCustomers.map(
                            (item) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.person_outline),
                              title: Text(item.name),
                              subtitle: Text(
                                '${item.transactionCount} transactions',
                              ),
                              trailing: Text(
                                _formatCurrency(item.totalAmount, currencyCode),
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _RangeTotals {
  final double totalCredit;
  final double totalDebit;
  final double net;
  final double averageTicket;
  final double maxTransaction;

  const _RangeTotals({
    required this.totalCredit,
    required this.totalDebit,
    required this.net,
    required this.averageTicket,
    required this.maxTransaction,
  });

  factory _RangeTotals.fromTransactions(List<txn_model.Transaction> txns) {
    var credit = 0.0;
    var debit = 0.0;
    var maxTxn = 0.0;

    for (final txn in txns) {
      if (txn.type == TransactionType.credit) {
        credit += txn.amount;
      } else {
        debit += txn.amount;
      }
      if (txn.amount > maxTxn) {
        maxTxn = txn.amount;
      }
    }

    final count = txns.length;
    final totalVolume = credit + debit;
    return _RangeTotals(
      totalCredit: credit,
      totalDebit: debit,
      net: credit - debit,
      averageTicket: count == 0 ? 0 : totalVolume / count,
      maxTransaction: maxTxn,
    );
  }
}

class _AnalyticsSnapshot {
  final String profileName;
  final int activeCustomerCount;
  final int totalCustomerCount;
  final int deletedTransactionCount;
  final int rangeTransactionsCount;
  final int photoAttachmentCount;
  final _RangeTotals totals;
  final double dueAmount;
  final double advanceAmount;
  final int dueCustomers;
  final int advanceCustomers;
  final List<_TopCustomerItem> topCustomers;
  final List<_DailyNetPoint> dailyNetSeries;
  final DateTime? startDate;
  final DateTime endDate;

  const _AnalyticsSnapshot({
    required this.profileName,
    required this.activeCustomerCount,
    required this.totalCustomerCount,
    required this.deletedTransactionCount,
    required this.rangeTransactionsCount,
    required this.photoAttachmentCount,
    required this.totals,
    required this.dueAmount,
    required this.advanceAmount,
    required this.dueCustomers,
    required this.advanceCustomers,
    required this.topCustomers,
    required this.dailyNetSeries,
    required this.startDate,
    required this.endDate,
  });

  factory _AnalyticsSnapshot.empty() {
    return _AnalyticsSnapshot(
      profileName: 'Business',
      activeCustomerCount: 0,
      totalCustomerCount: 0,
      deletedTransactionCount: 0,
      rangeTransactionsCount: 0,
      photoAttachmentCount: 0,
      totals: const _RangeTotals(
        totalCredit: 0,
        totalDebit: 0,
        net: 0,
        averageTicket: 0,
        maxTransaction: 0,
      ),
      dueAmount: 0,
      advanceAmount: 0,
      dueCustomers: 0,
      advanceCustomers: 0,
      topCustomers: const [],
      dailyNetSeries: const [],
      startDate: null,
      endDate: DateTime.now(),
    );
  }

  String get dateRangeLabel {
    final formatter = DateFormat('dd MMM yyyy');
    if (startDate == null) {
      return 'All time up to ${formatter.format(endDate)}';
    }
    return '${formatter.format(startDate!)} - ${formatter.format(endDate)}';
  }
}

class _TopCustomerItem {
  final String name;
  final double totalAmount;
  final int transactionCount;

  const _TopCustomerItem({
    required this.name,
    required this.totalAmount,
    required this.transactionCount,
  });
}

class _DailyNetPoint {
  final DateTime day;
  final double dayOffset;
  final double netAmount;

  const _DailyNetPoint({
    required this.day,
    required this.dayOffset,
    required this.netAmount,
  });
}

class _MetricGrid extends StatelessWidget {
  final List<_MetricItem> items;
  const _MetricGrid({required this.items});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      itemCount: items.length,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 2.2,
      ),
      itemBuilder: (context, index) {
        final item = items[index];
        return Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(item.icon),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        item.value,
                        style: Theme.of(context).textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MetricItem {
  final String title;
  final String value;
  final IconData icon;

  const _MetricItem({
    required this.title,
    required this.value,
    required this.icon,
  });
}

class _InlineStat extends StatelessWidget {
  final String label;
  final String value;

  const _InlineStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Text(value, style: Theme.of(context).textTheme.titleSmall),
        ],
      ),
    );
  }
}

class _CashflowPieCard extends StatelessWidget {
  final double credit;
  final double debit;
  final String creditLabel;
  final String debitLabel;
  final String Function(double amount) formatter;

  const _CashflowPieCard({
    required this.credit,
    required this.debit,
    required this.creditLabel,
    required this.debitLabel,
    required this.formatter,
  });

  @override
  Widget build(BuildContext context) {
    final total = credit + debit;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$creditLabel vs $debitLabel',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 170,
              child: total == 0
                  ? const Center(child: Text('No data for selected range'))
                  : Row(
                      children: [
                        Expanded(
                          child: PieChart(
                            PieChartData(
                              sectionsSpace: 2,
                              centerSpaceRadius: 30,
                              sections: [
                                PieChartSectionData(
                                  value: credit,
                                  title: '',
                                  color: Theme.of(context).colorScheme.primary,
                                  radius: 52,
                                ),
                                PieChartSectionData(
                                  value: debit,
                                  title: '',
                                  color: Theme.of(context).colorScheme.error,
                                  radius: 52,
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _LegendRow(
                                color: Theme.of(context).colorScheme.primary,
                                label: creditLabel,
                                value: formatter(credit),
                              ),
                              const SizedBox(height: 8),
                              _LegendRow(
                                color: Theme.of(context).colorScheme.error,
                                label: debitLabel,
                                value: formatter(debit),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DailyNetCard extends StatelessWidget {
  final List<_DailyNetPoint> points;
  final String Function(double amount) formatter;

  const _DailyNetCard({required this.points, required this.formatter});

  @override
  Widget build(BuildContext context) {
    final yValues = points.map((point) => point.netAmount).toList();
    final rawMinY = yValues.isEmpty
        ? 0.0
        : yValues.reduce((a, b) => a < b ? a : b);
    final rawMaxY = yValues.isEmpty
        ? 0.0
        : yValues.reduce((a, b) => a > b ? a : b);
    final minY = rawMinY == rawMaxY ? rawMinY - 1 : rawMinY;
    final maxY = rawMinY == rawMaxY ? rawMaxY + 1 : rawMaxY;
    final minX = points.isEmpty ? 0.0 : points.first.dayOffset;
    final maxX = points.isEmpty
        ? 1.0
        : (points.first.dayOffset == points.last.dayOffset
              ? points.last.dayOffset + 1
              : points.last.dayOffset);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Daily Net Trend',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 220,
              child: points.isEmpty
                  ? const Center(
                      child: Text('No trend data for selected range'),
                    )
                  : LineChart(
                      LineChartData(
                        minX: minX,
                        maxX: maxX,
                        minY: minY,
                        maxY: maxY,
                        gridData: FlGridData(
                          show: true,
                          drawVerticalLine: false,
                          horizontalInterval: _lineInterval(points),
                        ),
                        titlesData: FlTitlesData(
                          topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          leftTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 52,
                              getTitlesWidget: (value, meta) {
                                return Text(
                                  formatter(value),
                                  style: Theme.of(context).textTheme.bodySmall,
                                  maxLines: 1,
                                  overflow: TextOverflow.fade,
                                );
                              },
                            ),
                          ),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              interval: _xInterval(points),
                              getTitlesWidget: (value, meta) {
                                final match = points
                                    .where((point) => point.dayOffset == value)
                                    .toList();
                                if (match.isEmpty) {
                                  return const SizedBox.shrink();
                                }
                                return Text(
                                  DateFormat('dd MMM').format(match.first.day),
                                  style: Theme.of(context).textTheme.bodySmall,
                                );
                              },
                            ),
                          ),
                        ),
                        borderData: FlBorderData(
                          show: true,
                          border: Border(
                            left: BorderSide(
                              color: Theme.of(context).dividerColor,
                            ),
                            bottom: BorderSide(
                              color: Theme.of(context).dividerColor,
                            ),
                            top: BorderSide.none,
                            right: BorderSide.none,
                          ),
                        ),
                        lineBarsData: [
                          LineChartBarData(
                            spots: points
                                .map(
                                  (point) =>
                                      FlSpot(point.dayOffset, point.netAmount),
                                )
                                .toList(),
                            isCurved: true,
                            barWidth: 3,
                            color: Theme.of(context).colorScheme.primary,
                            dotData: const FlDotData(show: false),
                            belowBarData: BarAreaData(
                              show: true,
                              color: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.15),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  double _lineInterval(List<_DailyNetPoint> points) {
    final min = points
        .map((point) => point.netAmount)
        .reduce((a, b) => a < b ? a : b);
    final max = points
        .map((point) => point.netAmount)
        .reduce((a, b) => a > b ? a : b);
    final span = (max - min).abs();
    if (span == 0) return max == 0 ? 1 : max.abs();
    return span / 4;
  }

  double _xInterval(List<_DailyNetPoint> points) {
    if (points.length <= 1) return 1;
    final fullSpan = (points.last.dayOffset - points.first.dayOffset).abs();
    if (fullSpan <= 6) return 1;
    if (fullSpan <= 14) return 2;
    if (fullSpan <= 31) return 5;
    return 10;
  }
}

class _LegendRow extends StatelessWidget {
  final Color color;
  final String label;
  final String value;

  const _LegendRow({
    required this.color,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(label)),
        Text(value, style: Theme.of(context).textTheme.labelLarge),
      ],
    );
  }
}
