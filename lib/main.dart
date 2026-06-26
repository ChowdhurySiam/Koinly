import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:mongo_dart/mongo_dart.dart' as mongo;
import 'package:local_auth/local_auth.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sql;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as sqflite_ffi;
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

const Color kSleekBackground = Color(0xFF061012);
const Color kSleekSurface = Color(0xFF10191D);
const Color kSleekSurfaceHigh = Color(0xFF162226);
const Color kSleekSurfaceHigher = Color(0xFF1B2A2F);
const Color kSleekAccent = Color(0xFF00C7D8);
const Color kSleekIncome = Color(0xFF27D17F);
const Color kSleekExpense = Color(0xFFFF5353);
const Color kSleekWarning = Color(0xFFF59E0B);
const Color kSleekMuted = Color(0xFF7C8A92);

const appTitle = 'Koinly';
const appVersion = '1.0.67';
const backupPassword = 'YOUR_SECRET_PASSWORD';
const kSyncAdminTelegramUrl = 'https://t.me/Ch0wdhury_Siam';

bool get kUsesDesktopSqlite => !kIsWeb && (Platform.isWindows || Platform.isLinux);
bool get kIsDesktopApp => !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
bool get kSupportsLocalNotifications => !kIsWeb && Platform.isAndroid;

// Desktop builds store SharedPreferences separately from Android. Older Windows
// builds could inherit `onboardingCompleted=true` and skip the setup flow.
// Bumping this desktop setup marker forces the setup pages to appear once on PC
// without resetting mobile users or deleting any finance data. Revision 20260621 also
// corrects installs that previously skipped the Windows setup flow.
const int kRequiredDesktopSetupVersion = 20260623;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kUsesDesktopSqlite) {
    sqflite_ffi.sqfliteFfiInit();
    sql.databaseFactory = sqflite_ffi.databaseFactoryFfi;
  }
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
  ));

  try {
    await Firebase.initializeApp();
    FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
    PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };
  } catch (_) {
    // Firebase remains optional for local builds without a generated FlutterFire options file.
  }

  await ReminderService.ensureInitialized();

  runApp(
    ChangeNotifierProvider(
      create: (_) => AppController()..initialize(),
      child: const KoinlyApp(),
    ),
  );
}

// -----------------------------------------------------------------------------
// Models
// -----------------------------------------------------------------------------

enum AccountType { regular, credit, savings }
enum CategoryType { income, expense }
enum MoneyTransactionType { income, expense, transfer }
enum LoanType { given, taken }
enum LoanStatus { open, completed }
enum DateRangeType { today, thisWeek, thisMonth, thisYear, allTime, custom }
enum FinancialHealthPeriod { monthly, yearly }
enum CurrencyPosition { prefix, suffix }
enum ThemePreference { system, light, dark, batterySaver }
enum SyncDatabaseProvider { turso, mongoDb, local, cloudflareD1, supabase, neonPostgres, firebaseFirestore }

const List<SyncDatabaseProvider> userSyncDatabaseProviders = [
  SyncDatabaseProvider.mongoDb,
];

String enumName(Object value) => value.toString().split('.').last;

T enumByName<T>(Iterable<T> values, String? name, T fallback) {
  if (name == null) return fallback;
  for (final value in values) {
    if (enumName(value as Object) == name) return value;
  }
  return fallback;
}

String syncDatabaseProviderLabel(SyncDatabaseProvider provider) {
  switch (provider) {
    case SyncDatabaseProvider.turso:
      return 'Turso Database (hidden)';
    case SyncDatabaseProvider.mongoDb:
      return 'MongoDB Database';
    case SyncDatabaseProvider.local:
      return 'Local Database';
    case SyncDatabaseProvider.cloudflareD1:
      return 'Cloudflare D1';
    case SyncDatabaseProvider.supabase:
      return 'Supabase Postgres';
    case SyncDatabaseProvider.neonPostgres:
      return 'Neon Postgres';
    case SyncDatabaseProvider.firebaseFirestore:
      return 'Firebase Firestore';
  }
}

IconData syncDatabaseProviderIcon(SyncDatabaseProvider provider) {
  switch (provider) {
    case SyncDatabaseProvider.turso:
      return Icons.block_rounded;
    case SyncDatabaseProvider.mongoDb:
      return Icons.storage_rounded;
    case SyncDatabaseProvider.local:
      return Icons.phone_android_rounded;
    case SyncDatabaseProvider.cloudflareD1:
      return Icons.cloud_queue_rounded;
    case SyncDatabaseProvider.supabase:
      return Icons.account_tree_rounded;
    case SyncDatabaseProvider.neonPostgres:
      return Icons.auto_awesome_rounded;
    case SyncDatabaseProvider.firebaseFirestore:
      return Icons.local_fire_department_rounded;
  }
}

String syncDatabaseProviderSubtitle(SyncDatabaseProvider provider) {
  switch (provider) {
    case SyncDatabaseProvider.turso:
      return 'Hidden for users until Turso sync is ready again.';
    case SyncDatabaseProvider.mongoDb:
      return 'Use a MongoDB URL to store app sync snapshots.';
    case SyncDatabaseProvider.local:
      return 'Keep data on this device only. No cloud credentials required.';
    case SyncDatabaseProvider.cloudflareD1:
      return 'Free Cloudflare database option through your Koinly Worker API.';
    case SyncDatabaseProvider.supabase:
      return 'Free Supabase Postgres option through your Koinly Worker API.';
    case SyncDatabaseProvider.neonPostgres:
      return 'Free Neon Postgres option through your Koinly Worker API.';
    case SyncDatabaseProvider.firebaseFirestore:
      return 'Free Firebase Firestore option through your Koinly Worker API.';
  }
}

String redactSyncSecrets(String value) {
  return value
      .replaceAll(RegExp(r'mongodb(\+srv)?:\/\/[^\s\)\]\}]+', caseSensitive: false), 'mongodb://••••')
      .replaceAll(RegExp(r'Bearer\s+[A-Za-z0-9._~+\/=-]+', caseSensitive: false), 'Bearer ••••')
      .replaceAllMapped(RegExp(r'(token|password|auth)[=:]\s*[^,;\s]+', caseSensitive: false), (match) => '${match.group(1)}=••••');
}


DateTime dateFromDb(Object? value) {
  if (value == null) return DateTime.now();
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  if (value is String) return DateTime.tryParse(value) ?? DateTime.now();
  return DateTime.now();
}

int dateToDb(DateTime value) => value.millisecondsSinceEpoch;

Color colorFromHex(String value, {Color fallback = const Color(0xFF78D8E8)}) {
  final cleaned = value.replaceAll('#', '').trim();
  if (cleaned.isEmpty) return fallback;
  final normalized = cleaned.length == 6 ? 'FF$cleaned' : cleaned;
  return Color(int.tryParse(normalized, radix: 16) ?? fallback.value);
}

String colorToHex(Color color) => '#${color.value.toRadixString(16).padLeft(8, '0').substring(2)}';

class Account {
  Account({
    required this.id,
    required this.name,
    required this.type,
    required this.iconName,
    required this.iconColor,
    required this.amount,
    required this.creditLimit,
    required this.sequence,
    required this.createdOn,
    required this.updatedOn,
  });

  final String id;
  final String name;
  final AccountType type;
  final String iconName;
  final String iconColor;
  final double amount;
  final double creditLimit;
  final int sequence;
  final DateTime createdOn;
  final DateTime updatedOn;

  double get availableCredit => type == AccountType.credit ? creditLimit + amount : 0;

  Account copyWith({
    String? id,
    String? name,
    AccountType? type,
    String? iconName,
    String? iconColor,
    double? amount,
    double? creditLimit,
    int? sequence,
    DateTime? createdOn,
    DateTime? updatedOn,
  }) => Account(
        id: id ?? this.id,
        name: name ?? this.name,
        type: type ?? this.type,
        iconName: iconName ?? this.iconName,
        iconColor: iconColor ?? this.iconColor,
        amount: amount ?? this.amount,
        creditLimit: creditLimit ?? this.creditLimit,
        sequence: sequence ?? this.sequence,
        createdOn: createdOn ?? this.createdOn,
        updatedOn: updatedOn ?? this.updatedOn,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'type': enumName(type),
        'icon_name': iconName,
        'icon_color': iconColor,
        'amount': amount,
        'credit_limit': creditLimit,
        'sequence': sequence,
        'created_on': dateToDb(createdOn),
        'updated_on': dateToDb(updatedOn),
      };

  static Account fromMap(Map<String, Object?> map) => Account(
        id: map['id'] as String,
        name: map['name'] as String,
        type: enumByName(AccountType.values, map['type'] as String?, AccountType.regular),
        iconName: map['icon_name'] as String? ?? 'wallet',
        iconColor: map['icon_color'] as String? ?? '#78D8E8',
        amount: (map['amount'] as num? ?? 0).toDouble(),
        creditLimit: (map['credit_limit'] as num? ?? 0).toDouble(),
        sequence: (map['sequence'] as num? ?? 0).toInt(),
        createdOn: dateFromDb(map['created_on']),
        updatedOn: dateFromDb(map['updated_on']),
      );
}

class Category {
  Category({
    required this.id,
    required this.name,
    required this.type,
    required this.iconName,
    required this.iconColor,
    required this.createdOn,
    required this.updatedOn,
  });

  final String id;
  final String name;
  final CategoryType type;
  final String iconName;
  final String iconColor;
  final DateTime createdOn;
  final DateTime updatedOn;

  Category copyWith({
    String? id,
    String? name,
    CategoryType? type,
    String? iconName,
    String? iconColor,
    DateTime? createdOn,
    DateTime? updatedOn,
  }) => Category(
        id: id ?? this.id,
        name: name ?? this.name,
        type: type ?? this.type,
        iconName: iconName ?? this.iconName,
        iconColor: iconColor ?? this.iconColor,
        createdOn: createdOn ?? this.createdOn,
        updatedOn: updatedOn ?? this.updatedOn,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'type': enumName(type),
        'icon_name': iconName,
        'icon_color': iconColor,
        'created_on': dateToDb(createdOn),
        'updated_on': dateToDb(updatedOn),
      };

  static Category fromMap(Map<String, Object?> map) => Category(
        id: map['id'] as String,
        name: map['name'] as String,
        type: enumByName(CategoryType.values, map['type'] as String?, CategoryType.expense),
        iconName: map['icon_name'] as String? ?? 'category',
        iconColor: map['icon_color'] as String? ?? '#78D8E8',
        createdOn: dateFromDb(map['created_on']),
        updatedOn: dateFromDb(map['updated_on']),
      );

  bool get isLoanSystemCategory => const {
        'Loan Given',
        'Loan Taken',
        'Loan Repayment Received',
        'Loan Repayment Paid',
      }.contains(name);
}

class MoneyTransaction {
  MoneyTransaction({
    required this.id,
    required this.type,
    required this.amount,
    required this.notes,
    required this.categoryId,
    required this.fromAccountId,
    this.toAccountId,
    this.imagePath = '',
    this.loanId,
    this.repaymentId,
    required this.createdOn,
    required this.updatedOn,
  });

  final String id;
  final MoneyTransactionType type;
  final double amount;
  final String notes;
  final String categoryId;
  final String fromAccountId;
  final String? toAccountId;
  final String imagePath;
  final String? loanId;
  final String? repaymentId;
  final DateTime createdOn;
  final DateTime updatedOn;

  bool get isLoanMovement => loanId != null;
  bool get isLoanPrincipal => loanId != null && repaymentId == null;
  bool get isLoanRepayment => loanId != null && repaymentId != null;

  // Loan principal and repayment movements update account balances, but they are
  // balance-sheet movements rather than income or expense for reports.
  bool get countsAsIncome => type == MoneyTransactionType.income && !isLoanMovement;
  bool get countsAsExpense => type == MoneyTransactionType.expense && !isLoanMovement;

  String get displayType {
    if (isLoanPrincipal) {
      return type == MoneyTransactionType.income ? 'Loan Taken' : 'Loan Given';
    }
    if (isLoanRepayment) {
      return type == MoneyTransactionType.income ? 'Loan Repayment Received' : 'Loan Repayment Paid';
    }
    return enumName(type);
  }

  MoneyTransaction copyWith({
    String? id,
    MoneyTransactionType? type,
    double? amount,
    String? notes,
    String? categoryId,
    String? fromAccountId,
    String? toAccountId,
    String? imagePath,
    String? loanId,
    String? repaymentId,
    DateTime? createdOn,
    DateTime? updatedOn,
  }) => MoneyTransaction(
        id: id ?? this.id,
        type: type ?? this.type,
        amount: amount ?? this.amount,
        notes: notes ?? this.notes,
        categoryId: categoryId ?? this.categoryId,
        fromAccountId: fromAccountId ?? this.fromAccountId,
        toAccountId: toAccountId ?? this.toAccountId,
        imagePath: imagePath ?? this.imagePath,
        loanId: loanId ?? this.loanId,
        repaymentId: repaymentId ?? this.repaymentId,
        createdOn: createdOn ?? this.createdOn,
        updatedOn: updatedOn ?? this.updatedOn,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'type': enumName(type),
        'amount': amount,
        'notes': notes,
        'category_id': categoryId,
        'from_account_id': fromAccountId,
        'to_account_id': toAccountId,
        'image_path': imagePath,
        'loan_id': loanId,
        'repayment_id': repaymentId,
        'created_on': dateToDb(createdOn),
        'updated_on': dateToDb(updatedOn),
      };

  static MoneyTransaction fromMap(Map<String, Object?> map) => MoneyTransaction(
        id: map['id'] as String,
        type: enumByName(MoneyTransactionType.values, map['type'] as String?, MoneyTransactionType.expense),
        amount: (map['amount'] as num? ?? 0).toDouble(),
        notes: map['notes'] as String? ?? '',
        categoryId: map['category_id'] as String? ?? '',
        fromAccountId: map['from_account_id'] as String? ?? '',
        toAccountId: map['to_account_id'] as String?,
        imagePath: map['image_path'] as String? ?? '',
        loanId: map['loan_id'] as String?,
        repaymentId: map['repayment_id'] as String?,
        createdOn: dateFromDb(map['created_on']),
        updatedOn: dateFromDb(map['updated_on']),
      );
}

class Budget {
  Budget({
    required this.id,
    required this.selectedMonth,
    required this.amount,
    required this.allAccountsSelected,
    required this.allCategoriesSelected,
    required this.accountIds,
    required this.categoryIds,
    required this.createdOn,
    required this.updatedOn,
  });

  final String id;
  final DateTime selectedMonth;
  final double amount;
  final bool allAccountsSelected;
  final bool allCategoriesSelected;
  final List<String> accountIds;
  final List<String> categoryIds;
  final DateTime createdOn;
  final DateTime updatedOn;

  Map<String, Object?> toMap() => {
        'id': id,
        'selected_month': DateFormat('yyyy-MM').format(selectedMonth),
        'amount': amount,
        'all_accounts_selected': allAccountsSelected ? 1 : 0,
        'all_categories_selected': allCategoriesSelected ? 1 : 0,
        'created_on': dateToDb(createdOn),
        'updated_on': dateToDb(updatedOn),
      };

  static Budget fromMap(Map<String, Object?> map, List<String> accountIds, List<String> categoryIds) {
    final month = DateTime.tryParse('${map['selected_month'] as String? ?? DateFormat('yyyy-MM').format(DateTime.now())}-01') ?? DateTime.now();
    return Budget(
      id: map['id'] as String,
      selectedMonth: month,
      amount: (map['amount'] as num? ?? 0).toDouble(),
      allAccountsSelected: (map['all_accounts_selected'] as num? ?? 1).toInt() == 1,
      allCategoriesSelected: (map['all_categories_selected'] as num? ?? 1).toInt() == 1,
      accountIds: accountIds,
      categoryIds: categoryIds,
      createdOn: dateFromDb(map['created_on']),
      updatedOn: dateFromDb(map['updated_on']),
    );
  }

  Budget copyWith({
    String? id,
    DateTime? selectedMonth,
    double? amount,
    bool? allAccountsSelected,
    bool? allCategoriesSelected,
    List<String>? accountIds,
    List<String>? categoryIds,
    DateTime? createdOn,
    DateTime? updatedOn,
  }) => Budget(
        id: id ?? this.id,
        selectedMonth: selectedMonth ?? this.selectedMonth,
        amount: amount ?? this.amount,
        allAccountsSelected: allAccountsSelected ?? this.allAccountsSelected,
        allCategoriesSelected: allCategoriesSelected ?? this.allCategoriesSelected,
        accountIds: accountIds ?? this.accountIds,
        categoryIds: categoryIds ?? this.categoryIds,
        createdOn: createdOn ?? this.createdOn,
        updatedOn: updatedOn ?? this.updatedOn,
      );
}

class Loan {
  Loan({
    required this.id,
    required this.type,
    required this.accountId,
    required this.personName,
    required this.amount,
    required this.loanDate,
    this.dueDate,
    required this.notes,
    required this.repaidAmount,
    required this.status,
    required this.createdOn,
    required this.updatedOn,
  });

  final String id;
  final LoanType type;
  final String accountId;
  final String personName;
  final double amount;
  final DateTime loanDate;
  final DateTime? dueDate;
  final String notes;
  final double repaidAmount;
  final LoanStatus status;
  final DateTime createdOn;
  final DateTime updatedOn;

  double get remainingAmount => math.max<double>(0.0, amount - repaidAmount);
  bool get isCompleted => status == LoanStatus.completed || remainingAmount <= 0.0001;

  Map<String, Object?> toMap() => {
        'id': id,
        'type': enumName(type),
        'account_id': accountId,
        'person_name': personName,
        'amount': amount,
        'loan_date': dateToDb(loanDate),
        'due_date': dueDate == null ? null : dateToDb(dueDate!),
        'notes': notes,
        'repaid_amount': repaidAmount,
        'status': enumName(status),
        'created_on': dateToDb(createdOn),
        'updated_on': dateToDb(updatedOn),
      };

  static Loan fromMap(Map<String, Object?> map) => Loan(
        id: map['id'] as String,
        type: enumByName(LoanType.values, map['type'] as String?, LoanType.given),
        accountId: map['account_id'] as String? ?? '',
        personName: map['person_name'] as String? ?? '',
        amount: (map['amount'] as num? ?? 0).toDouble(),
        loanDate: dateFromDb(map['loan_date']),
        dueDate: map['due_date'] == null ? null : dateFromDb(map['due_date']),
        notes: map['notes'] as String? ?? '',
        repaidAmount: (map['repaid_amount'] as num? ?? 0).toDouble(),
        status: enumByName(LoanStatus.values, map['status'] as String?, LoanStatus.open),
        createdOn: dateFromDb(map['created_on']),
        updatedOn: dateFromDb(map['updated_on']),
      );

  Loan copyWith({
    String? id,
    LoanType? type,
    String? accountId,
    String? personName,
    double? amount,
    DateTime? loanDate,
    DateTime? dueDate,
    String? notes,
    double? repaidAmount,
    LoanStatus? status,
    DateTime? createdOn,
    DateTime? updatedOn,
  }) => Loan(
        id: id ?? this.id,
        type: type ?? this.type,
        accountId: accountId ?? this.accountId,
        personName: personName ?? this.personName,
        amount: amount ?? this.amount,
        loanDate: loanDate ?? this.loanDate,
        dueDate: dueDate ?? this.dueDate,
        notes: notes ?? this.notes,
        repaidAmount: repaidAmount ?? this.repaidAmount,
        status: status ?? this.status,
        createdOn: createdOn ?? this.createdOn,
        updatedOn: updatedOn ?? this.updatedOn,
      );
}

class LoanRepayment {
  LoanRepayment({
    required this.id,
    required this.loanId,
    required this.accountId,
    required this.amount,
    required this.paidOn,
    required this.notes,
    required this.createdOn,
  });

  final String id;
  final String loanId;
  final String accountId;
  final double amount;
  final DateTime paidOn;
  final String notes;
  final DateTime createdOn;

  Map<String, Object?> toMap() => {
        'id': id,
        'loan_id': loanId,
        'account_id': accountId,
        'amount': amount,
        'paid_on': dateToDb(paidOn),
        'notes': notes,
        'created_on': dateToDb(createdOn),
      };

  static LoanRepayment fromMap(Map<String, Object?> map) => LoanRepayment(
        id: map['id'] as String,
        loanId: map['loan_id'] as String? ?? '',
        accountId: map['account_id'] as String? ?? '',
        amount: (map['amount'] as num? ?? 0).toDouble(),
        paidOn: dateFromDb(map['paid_on']),
        notes: map['notes'] as String? ?? '',
        createdOn: dateFromDb(map['created_on']),
      );
}


class LoanRepaymentReminder {
  LoanRepaymentReminder({
    required this.id,
    required this.loanId,
    required this.accountId,
    required this.amount,
    required this.dueDate,
    required this.reminderTimeMinutes,
    required this.notes,
    required this.isPaid,
    this.paidOn,
    required this.createdOn,
    required this.updatedOn,
  });

  final String id;
  final String loanId;
  final String accountId;
  final double amount;
  final DateTime dueDate;
  final int reminderTimeMinutes;
  final String notes;
  final bool isPaid;
  final DateTime? paidOn;
  final DateTime createdOn;
  final DateTime updatedOn;

  bool get isOverdue {
    if (isPaid) return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dueDay = DateTime(dueDate.year, dueDate.month, dueDate.day);
    return dueDay.isBefore(today);
  }

  bool get isDueToday {
    if (isPaid) return false;
    final now = DateTime.now();
    return dueDate.year == now.year && dueDate.month == now.month && dueDate.day == now.day;
  }

  DateTime get reminderAt {
    final hour = reminderTimeMinutes ~/ 60;
    final minute = reminderTimeMinutes % 60;
    return DateTime(dueDate.year, dueDate.month, dueDate.day, hour, minute);
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'loan_id': loanId,
        'account_id': accountId,
        'amount': amount,
        'due_date': dateToDb(dueDate),
        'reminder_time_minutes': reminderTimeMinutes,
        'notes': notes,
        'is_paid': isPaid ? 1 : 0,
        'paid_on': paidOn == null ? null : dateToDb(paidOn!),
        'created_on': dateToDb(createdOn),
        'updated_on': dateToDb(updatedOn),
      };

  static LoanRepaymentReminder fromMap(Map<String, Object?> map) => LoanRepaymentReminder(
        id: map['id'] as String,
        loanId: map['loan_id'] as String? ?? '',
        accountId: map['account_id'] as String? ?? '',
        amount: (map['amount'] as num? ?? 0).toDouble(),
        dueDate: dateFromDb(map['due_date']),
        reminderTimeMinutes: (map['reminder_time_minutes'] as num? ?? (9 * 60)).toInt(),
        notes: map['notes'] as String? ?? '',
        isPaid: (map['is_paid'] as num? ?? 0).toInt() == 1,
        paidOn: map['paid_on'] == null ? null : dateFromDb(map['paid_on']),
        createdOn: dateFromDb(map['created_on']),
        updatedOn: dateFromDb(map['updated_on']),
      );

  LoanRepaymentReminder copyWith({
    String? id,
    String? loanId,
    String? accountId,
    double? amount,
    DateTime? dueDate,
    int? reminderTimeMinutes,
    String? notes,
    bool? isPaid,
    DateTime? paidOn,
    DateTime? createdOn,
    DateTime? updatedOn,
  }) => LoanRepaymentReminder(
        id: id ?? this.id,
        loanId: loanId ?? this.loanId,
        accountId: accountId ?? this.accountId,
        amount: amount ?? this.amount,
        dueDate: dueDate ?? this.dueDate,
        reminderTimeMinutes: reminderTimeMinutes ?? this.reminderTimeMinutes,
        notes: notes ?? this.notes,
        isPaid: isPaid ?? this.isPaid,
        paidOn: paidOn ?? this.paidOn,
        createdOn: createdOn ?? this.createdOn,
        updatedOn: updatedOn ?? this.updatedOn,
      );
}


class SavingsSuggestionProfile {
  const SavingsSuggestionProfile({
    required this.completed,
    required this.hobby,
    required this.occupation,
    required this.age,
    required this.savingsGoal,
    required this.spendingPreference,
    required this.extraDetails,
    required this.updatedOn,
  });

  final bool completed;
  final String hobby;
  final String occupation;
  final int age;
  final String savingsGoal;
  final String spendingPreference;
  final String extraDetails;
  final DateTime? updatedOn;

  static const empty = SavingsSuggestionProfile(
    completed: false,
    hobby: '',
    occupation: '',
    age: 0,
    savingsGoal: '',
    spendingPreference: '',
    extraDetails: '',
    updatedOn: null,
  );

  bool get hasPersonalDetails => hobby.trim().isNotEmpty || occupation.trim().isNotEmpty || age > 0 || savingsGoal.trim().isNotEmpty || spendingPreference.trim().isNotEmpty || extraDetails.trim().isNotEmpty;

  String get shortLabel {
    final parts = [
      if (occupation.trim().isNotEmpty) occupation.trim(),
      if (hobby.trim().isNotEmpty) hobby.trim(),
      if (savingsGoal.trim().isNotEmpty) savingsGoal.trim(),
    ];
    if (parts.isEmpty) return completed ? 'Generic suggestions' : 'Not configured';
    return parts.take(2).join(' • ');
  }

  Map<String, dynamic> toJson() => {
        'completed': completed,
        'hobby': hobby,
        'occupation': occupation,
        'age': age,
        'savingsGoal': savingsGoal,
        'spendingPreference': spendingPreference,
        'extraDetails': extraDetails,
        'updatedOn': updatedOn?.toIso8601String() ?? '',
      };

  static SavingsSuggestionProfile fromJson(Map<String, dynamic> json) => SavingsSuggestionProfile(
        completed: json['completed'] as bool? ?? false,
        hobby: json['hobby'] as String? ?? '',
        occupation: json['occupation'] as String? ?? '',
        age: (json['age'] as num? ?? 0).toInt(),
        savingsGoal: json['savingsGoal'] as String? ?? '',
        spendingPreference: json['spendingPreference'] as String? ?? '',
        extraDetails: json['extraDetails'] as String? ?? '',
        updatedOn: (json['updatedOn'] as String? ?? '').isEmpty ? null : DateTime.tryParse(json['updatedOn'] as String),
      );

  static SavingsSuggestionProfile fromJsonString(String raw) {
    if (raw.trim().isEmpty) return SavingsSuggestionProfile.empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return SavingsSuggestionProfile.fromJson(decoded.cast<String, dynamic>());
    } catch (_) {}
    return SavingsSuggestionProfile.empty;
  }

  SavingsSuggestionProfile copyWith({
    bool? completed,
    String? hobby,
    String? occupation,
    int? age,
    String? savingsGoal,
    String? spendingPreference,
    String? extraDetails,
    DateTime? updatedOn,
  }) => SavingsSuggestionProfile(
        completed: completed ?? this.completed,
        hobby: hobby ?? this.hobby,
        occupation: occupation ?? this.occupation,
        age: age ?? this.age,
        savingsGoal: savingsGoal ?? this.savingsGoal,
        spendingPreference: spendingPreference ?? this.spendingPreference,
        extraDetails: extraDetails ?? this.extraDetails,
        updatedOn: updatedOn ?? this.updatedOn,
      );
}

class SavingsPurchaseSuggestion {
  const SavingsPurchaseSuggestion({
    required this.id,
    required this.title,
    required this.costRange,
    required this.reason,
    required this.savingsFit,
    required this.iconName,
    required this.color,
  });

  final String id;
  final String title;
  final String costRange;
  final String reason;
  final String savingsFit;
  final String iconName;
  final String color;
}

class DateRange {
  const DateRange(this.start, this.end, this.label);
  final DateTime? start;
  final DateTime? end;
  final String label;
}

class Summary {
  const Summary({required this.income, required this.expense});
  final double income;
  final double expense;
  double get balance => income - expense;
}

class BudgetProgress {
  BudgetProgress(this.budget, this.spent, this.transactions);
  final Budget budget;
  final double spent;
  final List<MoneyTransaction> transactions;
  double get ratio => budget.amount <= 0 ? 0 : spent / budget.amount;
}

// -----------------------------------------------------------------------------
// Database and persistence
// -----------------------------------------------------------------------------

class KoinlyDatabase {
  sql.Database? _db;

  Future<sql.Database> get db async {
    if (_db != null) return _db!;
    final dir = await sql.getDatabasesPath();
    final path = p.join(dir, 'koinly_flutter.db');
    _db = await sql.openDatabase(
      path,
      version: 5,
      onCreate: (database, version) async {
        await _createSchema(database);
        await _seed(database);
      },
      onUpgrade: (database, oldVersion, newVersion) async {
        await _createSchema(database);
        await _migrateLoanAccountSelection(database);
      },
      onOpen: (database) async {
        await _createSchema(database);
        await _migrateLoanAccountSelection(database);
      },
    );
    return _db!;
  }

  Future<void> _createSchema(sql.Database database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS accounts(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        type TEXT NOT NULL,
        icon_name TEXT NOT NULL,
        icon_color TEXT NOT NULL,
        amount REAL NOT NULL DEFAULT 0,
        credit_limit REAL NOT NULL DEFAULT 0,
        sequence INTEGER NOT NULL DEFAULT 0,
        created_on INTEGER NOT NULL,
        updated_on INTEGER NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS categories(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        type TEXT NOT NULL,
        icon_name TEXT NOT NULL,
        icon_color TEXT NOT NULL,
        created_on INTEGER NOT NULL,
        updated_on INTEGER NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS transactions(
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        amount REAL NOT NULL,
        notes TEXT NOT NULL,
        category_id TEXT NOT NULL,
        from_account_id TEXT NOT NULL,
        to_account_id TEXT,
        image_path TEXT NOT NULL DEFAULT '',
        loan_id TEXT,
        repayment_id TEXT,
        created_on INTEGER NOT NULL,
        updated_on INTEGER NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS budgets(
        id TEXT PRIMARY KEY,
        selected_month TEXT NOT NULL,
        amount REAL NOT NULL,
        all_accounts_selected INTEGER NOT NULL DEFAULT 1,
        all_categories_selected INTEGER NOT NULL DEFAULT 1,
        created_on INTEGER NOT NULL,
        updated_on INTEGER NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS budget_accounts(
        budget_id TEXT NOT NULL,
        account_id TEXT NOT NULL,
        PRIMARY KEY(budget_id, account_id)
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS budget_categories(
        budget_id TEXT NOT NULL,
        category_id TEXT NOT NULL,
        PRIMARY KEY(budget_id, category_id)
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS loans(
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        account_id TEXT NOT NULL,
        person_name TEXT NOT NULL,
        amount REAL NOT NULL,
        loan_date INTEGER NOT NULL,
        due_date INTEGER,
        notes TEXT NOT NULL,
        repaid_amount REAL NOT NULL DEFAULT 0,
        status TEXT NOT NULL,
        created_on INTEGER NOT NULL,
        updated_on INTEGER NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS loan_repayments(
        id TEXT PRIMARY KEY,
        loan_id TEXT NOT NULL,
        account_id TEXT NOT NULL DEFAULT '',
        amount REAL NOT NULL,
        paid_on INTEGER NOT NULL,
        notes TEXT NOT NULL,
        created_on INTEGER NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS loan_repayment_reminders(
        id TEXT PRIMARY KEY,
        loan_id TEXT NOT NULL,
        account_id TEXT NOT NULL DEFAULT '',
        amount REAL NOT NULL,
        due_date INTEGER NOT NULL,
        reminder_time_minutes INTEGER NOT NULL DEFAULT 540,
        notes TEXT NOT NULL,
        is_paid INTEGER NOT NULL DEFAULT 0,
        paid_on INTEGER,
        created_on INTEGER NOT NULL,
        updated_on INTEGER NOT NULL
      )
    ''');
  }

  Future<void> _migrateLoanAccountSelection(sql.Database database) async {
    try {
      await database.execute("ALTER TABLE loan_repayments ADD COLUMN account_id TEXT NOT NULL DEFAULT ''");
    } catch (_) {
      // Column already exists on fresh installs or after a previous migration.
    }

    // Backfill repayment account links from older hidden repayment
    // transactions before those legacy rows are removed.
    final legacyRepaymentTx = await database.query(
      'transactions',
      columns: ['repayment_id', 'from_account_id'],
      where: "repayment_id IS NOT NULL AND repayment_id != ''",
    );
    for (final tx in legacyRepaymentTx) {
      final repaymentId = tx['repayment_id'] as String? ?? '';
      final accountId = tx['from_account_id'] as String? ?? '';
      if (repaymentId.isNotEmpty && accountId.isNotEmpty) {
        await database.update('loan_repayments', {'account_id': accountId}, where: 'id = ?', whereArgs: [repaymentId]);
      }
    }

    // Older builds stored loan balance movements as hidden income/expense
    // transactions. The new loan system keeps loans separate and applies
    // balance changes directly to the selected account, so those legacy rows
    // should not remain in the normal transaction table.
    await database.delete('transactions', where: 'loan_id IS NOT NULL');
    await database.delete('categories', where: "name IN ('Loan Given', 'Loan Taken', 'Loan Repayment Received', 'Loan Repayment Paid')");

    // Backfill repayment account links from the parent loan when possible.
    final emptyRepayments = await database.query('loan_repayments', where: "account_id = '' OR account_id IS NULL");
    for (final repayment in emptyRepayments) {
      final loanId = repayment['loan_id'] as String? ?? '';
      final loanRows = await database.query('loans', columns: ['account_id'], where: 'id = ?', whereArgs: [loanId], limit: 1);
      if (loanRows.isNotEmpty) {
        await database.update('loan_repayments', {'account_id': loanRows.first['account_id'] ?? ''}, where: 'id = ?', whereArgs: [repayment['id']]);
      }
    }
  }

  Future<void> _seed(sql.Database database) async {
    final count = sql.Sqflite.firstIntValue(await database.rawQuery('SELECT COUNT(*) FROM accounts')) ?? 0;
    if (count > 0) return;
    final now = DateTime.now();
    final accounts = [
      Account(id: _uuid.v4(), name: 'Cash', type: AccountType.regular, iconName: 'wallet', iconColor: '#78D8E8', amount: 0, creditLimit: 0, sequence: 0, createdOn: now, updatedOn: now),
      Account(id: _uuid.v4(), name: 'Card', type: AccountType.credit, iconName: 'credit_card', iconColor: '#89A7FF', amount: 0, creditLimit: 0, sequence: 1, createdOn: now, updatedOn: now),
      Account(id: _uuid.v4(), name: 'Bank Account', type: AccountType.regular, iconName: 'bank', iconColor: '#A6E3A1', amount: 0, creditLimit: 0, sequence: 2, createdOn: now, updatedOn: now),
    ];
    for (final account in accounts) {
      await database.insert('accounts', account.toMap());
    }

    final expense = [
      ['Clothing', 'apparel', '#F5A3A3'],
      ['Entertainment', 'games', '#B5A7FF'],
      ['Food', 'food', '#FBC879'],
      ['Health', 'health', '#98E2C6'],
      ['Leisure', 'leisure', '#A7D0FF'],
      ['Shopping', 'cart', '#FFB5D0'],
      ['Transportation', 'car', '#AEE9F1'],
      ['Utilities', 'bolt', '#CCD6A6'],
    ];
    final income = [
      ['Salary', 'salary', '#A6E3A1'],
      ['Gift', 'gift', '#FFDE7D'],
      ['Coupons', 'coupon', '#B4A5FF'],
    ];
    for (final data in expense) {
      await database.insert('categories', Category(id: _uuid.v4(), name: data[0], type: CategoryType.expense, iconName: data[1], iconColor: data[2], createdOn: now, updatedOn: now).toMap());
    }
    for (final data in income) {
      await database.insert('categories', Category(id: _uuid.v4(), name: data[0], type: CategoryType.income, iconName: data[1], iconColor: data[2], createdOn: now, updatedOn: now).toMap());
    }
  }

  Future<List<Account>> accounts() async {
    final maps = await (await db).query('accounts', orderBy: 'sequence ASC, created_on ASC');
    return maps.map(Account.fromMap).toList();
  }

  Future<void> upsertAccount(Account account) async => (await db).insert('accounts', account.toMap(), conflictAlgorithm: sql.ConflictAlgorithm.replace);

  Future<void> deleteAccount(String id) async => (await db).delete('accounts', where: 'id = ?', whereArgs: [id]);

  Future<void> reorderAccounts(List<Account> ordered) async {
    final database = await db;
    await database.transaction((txn) async {
      for (var i = 0; i < ordered.length; i++) {
        await txn.update('accounts', {'sequence': i, 'updated_on': dateToDb(DateTime.now())}, where: 'id = ?', whereArgs: [ordered[i].id]);
      }
    });
  }

  Future<List<Category>> categories() async {
    final maps = await (await db).query('categories', orderBy: 'type ASC, name COLLATE NOCASE ASC');
    return maps.map(Category.fromMap).toList();
  }

  Future<void> upsertCategory(Category category) async => (await db).insert('categories', category.toMap(), conflictAlgorithm: sql.ConflictAlgorithm.replace);
  Future<void> deleteCategory(String id) async => (await db).delete('categories', where: 'id = ?', whereArgs: [id]);

  Future<List<MoneyTransaction>> transactions() async {
    final maps = await (await db).query('transactions', where: 'loan_id IS NULL', orderBy: 'created_on DESC, updated_on DESC');
    return maps.map(MoneyTransaction.fromMap).toList();
  }

  Future<void> addTransaction(MoneyTransaction transaction) async {
    if (transaction.type == MoneyTransactionType.transfer && transaction.fromAccountId == transaction.toAccountId) {
      throw StateError('Transfer source and destination account cannot be the same.');
    }
    final database = await db;
    await database.transaction((txn) async {
      await txn.insert('transactions', transaction.toMap(), conflictAlgorithm: sql.ConflictAlgorithm.replace);
      await _applyTransaction(txn, transaction, 1);
    });
  }

  Future<void> updateTransaction(MoneyTransaction updated) async {
    final database = await db;
    final oldRows = await database.query('transactions', where: 'id = ?', whereArgs: [updated.id], limit: 1);
    if (oldRows.isEmpty) {
      await addTransaction(updated);
      return;
    }
    final old = MoneyTransaction.fromMap(oldRows.first);
    await database.transaction((txn) async {
      await _applyTransaction(txn, old, -1);
      await txn.update('transactions', updated.toMap(), where: 'id = ?', whereArgs: [updated.id]);
      await _applyTransaction(txn, updated, 1);
    });
  }

  Future<void> deleteTransaction(String id) async {
    final database = await db;
    final oldRows = await database.query('transactions', where: 'id = ?', whereArgs: [id], limit: 1);
    if (oldRows.isEmpty) return;
    final old = MoneyTransaction.fromMap(oldRows.first);
    await database.transaction((txn) async {
      await _applyTransaction(txn, old, -1);
      await txn.delete('transactions', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<void> _applyTransaction(sql.Transaction txn, MoneyTransaction tx, int direction) async {
    Future<void> updateAmount(String accountId, double delta) async {
      if (accountId.isEmpty) return;
      await txn.rawUpdate('UPDATE accounts SET amount = amount + ?, updated_on = ? WHERE id = ?', [delta * direction, dateToDb(DateTime.now()), accountId]);
    }

    if (tx.type == MoneyTransactionType.income) {
      await updateAmount(tx.fromAccountId, tx.amount);
    } else if (tx.type == MoneyTransactionType.expense) {
      await updateAmount(tx.fromAccountId, -tx.amount);
    } else {
      await updateAmount(tx.fromAccountId, -tx.amount);
      await updateAmount(tx.toAccountId ?? '', tx.amount);
    }
  }

  Future<Category> ensureCategory(String name, CategoryType type, String color, String icon) async {
    final database = await db;
    final rows = await database.query('categories', where: 'name = ? AND type = ?', whereArgs: [name, enumName(type)], limit: 1);
    if (rows.isNotEmpty) return Category.fromMap(rows.first);
    final now = DateTime.now();
    final category = Category(id: _uuid.v4(), name: name, type: type, iconName: icon, iconColor: color, createdOn: now, updatedOn: now);
    await database.insert('categories', category.toMap());
    return category;
  }

  Future<List<Budget>> budgets() async {
    final database = await db;
    final rows = await database.query('budgets', orderBy: 'selected_month DESC');
    final result = <Budget>[];
    for (final row in rows) {
      final id = row['id'] as String;
      final accountIds = (await database.query('budget_accounts', columns: ['account_id'], where: 'budget_id = ?', whereArgs: [id])).map((e) => e['account_id'] as String).toList();
      final categoryIds = (await database.query('budget_categories', columns: ['category_id'], where: 'budget_id = ?', whereArgs: [id])).map((e) => e['category_id'] as String).toList();
      result.add(Budget.fromMap(row, accountIds, categoryIds));
    }
    return result;
  }

  Future<void> upsertBudget(Budget budget) async {
    final database = await db;
    await database.transaction((txn) async {
      await txn.insert('budgets', budget.toMap(), conflictAlgorithm: sql.ConflictAlgorithm.replace);
      await txn.delete('budget_accounts', where: 'budget_id = ?', whereArgs: [budget.id]);
      await txn.delete('budget_categories', where: 'budget_id = ?', whereArgs: [budget.id]);
      for (final accountId in budget.accountIds) {
        await txn.insert('budget_accounts', {'budget_id': budget.id, 'account_id': accountId});
      }
      for (final categoryId in budget.categoryIds) {
        await txn.insert('budget_categories', {'budget_id': budget.id, 'category_id': categoryId});
      }
    });
  }

  Future<void> deleteBudget(String id) async {
    final database = await db;
    await database.transaction((txn) async {
      await txn.delete('budget_accounts', where: 'budget_id = ?', whereArgs: [id]);
      await txn.delete('budget_categories', where: 'budget_id = ?', whereArgs: [id]);
      await txn.delete('budgets', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<List<Loan>> loans() async {
    final maps = await (await db).query('loans', orderBy: 'status ASC, loan_date DESC');
    return maps.map(Loan.fromMap).toList();
  }

  Future<List<LoanRepayment>> repayments(String loanId) async {
    final maps = await (await db).query('loan_repayments', where: 'loan_id = ?', whereArgs: [loanId], orderBy: 'paid_on DESC');
    return maps.map(LoanRepayment.fromMap).toList();
  }

  Future<List<LoanRepaymentReminder>> loanRepaymentReminders({String? loanId}) async {
    final database = await db;
    final maps = loanId == null
        ? await database.query('loan_repayment_reminders', orderBy: 'is_paid ASC, due_date ASC')
        : await database.query('loan_repayment_reminders', where: 'loan_id = ?', whereArgs: [loanId], orderBy: 'is_paid ASC, due_date ASC');
    return maps.map(LoanRepaymentReminder.fromMap).toList();
  }

  Future<void> replacePendingLoanRepaymentReminders(String loanId, List<LoanRepaymentReminder> reminders) async {
    final database = await db;
    await database.transaction((txn) async {
      await txn.delete('loan_repayment_reminders', where: 'loan_id = ? AND is_paid = 0', whereArgs: [loanId]);
      for (final reminder in reminders) {
        await txn.insert('loan_repayment_reminders', reminder.toMap(), conflictAlgorithm: sql.ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> deleteLoanRepaymentReminder(String id) async {
    await (await db).delete('loan_repayment_reminders', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> markLoanRepaymentReminderPaid(Loan loan, LoanRepaymentReminder reminder, String accountId) async {
    if (reminder.isPaid) return;
    final normalizedAmount = math.min(loan.remainingAmount, reminder.amount);
    if (normalizedAmount <= 0) return;
    final repayment = LoanRepayment(
      id: _uuid.v4(),
      loanId: loan.id,
      accountId: accountId,
      amount: normalizedAmount,
      paidOn: DateTime.now(),
      notes: reminder.notes,
      createdOn: DateTime.now(),
    );
    final newRepaid = math.min(loan.amount, loan.repaidAmount + repayment.amount);
    final updated = loan.copyWith(
      repaidAmount: newRepaid,
      status: newRepaid >= loan.amount ? LoanStatus.completed : LoanStatus.open,
      updatedOn: DateTime.now(),
    );
    final database = await db;
    await database.transaction((txn) async {
      await txn.insert('loan_repayments', repayment.toMap());
      await txn.update('loans', updated.toMap(), where: 'id = ?', whereArgs: [loan.id]);
      await _applyLoanRepayment(txn, loan, repayment, 1);
      await txn.update(
        'loan_repayment_reminders',
        reminder.copyWith(isPaid: true, paidOn: DateTime.now(), updatedOn: DateTime.now()).toMap(),
        where: 'id = ?',
        whereArgs: [reminder.id],
      );
    });
  }

  Future<void> _applyLoanPrincipal(sql.Transaction txn, Loan loan, int direction) async {
    if (loan.accountId.isEmpty) return;
    final delta = loan.type == LoanType.taken ? loan.amount : -loan.amount;
    await txn.rawUpdate(
      'UPDATE accounts SET amount = amount + ?, updated_on = ? WHERE id = ?',
      [delta * direction, dateToDb(DateTime.now()), loan.accountId],
    );
  }

  Future<void> _applyLoanRepayment(sql.Transaction txn, Loan loan, LoanRepayment repayment, int direction) async {
    final accountId = repayment.accountId.isNotEmpty ? repayment.accountId : loan.accountId;
    if (accountId.isEmpty) return;
    final delta = loan.type == LoanType.given ? repayment.amount : -repayment.amount;
    await txn.rawUpdate(
      'UPDATE accounts SET amount = amount + ?, updated_on = ? WHERE id = ?',
      [delta * direction, dateToDb(DateTime.now()), accountId],
    );
  }

  Future<void> addLoan(Loan loan) async {
    final database = await db;
    await database.transaction((txn) async {
      await txn.insert('loans', loan.toMap(), conflictAlgorithm: sql.ConflictAlgorithm.replace);
      await _applyLoanPrincipal(txn, loan, 1);
    });
  }

  Future<void> updateLoan(Loan updated) async {
    final database = await db;
    final rows = await database.query('loans', where: 'id = ?', whereArgs: [updated.id], limit: 1);
    if (rows.isEmpty) {
      await addLoan(updated);
      return;
    }
    final old = Loan.fromMap(rows.first);
    final repaymentRows = await database.query('loan_repayments', where: 'loan_id = ?', whereArgs: [updated.id]);
    final repayments = repaymentRows.map(LoanRepayment.fromMap).toList();
    await database.transaction((txn) async {
      for (final repayment in repayments) {
        await _applyLoanRepayment(txn, old, repayment, -1);
      }
      await _applyLoanPrincipal(txn, old, -1);
      await txn.update('loans', updated.toMap(), where: 'id = ?', whereArgs: [updated.id]);
      await _applyLoanPrincipal(txn, updated, 1);
      for (final repayment in repayments) {
        await _applyLoanRepayment(txn, updated, repayment, 1);
      }
      await txn.delete('transactions', where: 'loan_id = ?', whereArgs: [updated.id]);
    });
  }

  Future<void> deleteLoan(String id) async {
    final database = await db;
    final loanRows = await database.query('loans', where: 'id = ?', whereArgs: [id], limit: 1);
    if (loanRows.isEmpty) return;
    final loan = Loan.fromMap(loanRows.first);
    final repaymentRows = await database.query('loan_repayments', where: 'loan_id = ?', whereArgs: [id]);
    final repayments = repaymentRows.map(LoanRepayment.fromMap).toList();
    await database.transaction((txn) async {
      for (final repayment in repayments) {
        await _applyLoanRepayment(txn, loan, repayment, -1);
      }
      await _applyLoanPrincipal(txn, loan, -1);
      await txn.delete('transactions', where: 'loan_id = ?', whereArgs: [id]);
      await txn.delete('loan_repayments', where: 'loan_id = ?', whereArgs: [id]);
      await txn.delete('loan_repayment_reminders', where: 'loan_id = ?', whereArgs: [id]);
      await txn.delete('loans', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<void> addRepayment(Loan loan, LoanRepayment repayment, String accountId) async {
    final normalized = LoanRepayment(
      id: repayment.id,
      loanId: repayment.loanId,
      accountId: accountId,
      amount: repayment.amount,
      paidOn: repayment.paidOn,
      notes: repayment.notes,
      createdOn: repayment.createdOn,
    );
    final newRepaid = math.min(loan.amount, loan.repaidAmount + normalized.amount);
    final updated = loan.copyWith(
      repaidAmount: newRepaid,
      status: newRepaid >= loan.amount ? LoanStatus.completed : LoanStatus.open,
      updatedOn: DateTime.now(),
    );
    final database = await db;
    await database.transaction((txn) async {
      await txn.insert('loan_repayments', normalized.toMap());
      await txn.update('loans', updated.toMap(), where: 'id = ?', whereArgs: [loan.id]);
      await _applyLoanRepayment(txn, loan, normalized, 1);
      await txn.delete('transactions', where: 'repayment_id = ?', whereArgs: [normalized.id]);
    });
  }

  Future<void> deleteRepayment(String repaymentId) async {
    final database = await db;
    final rows = await database.query('loan_repayments', where: 'id = ?', whereArgs: [repaymentId], limit: 1);
    if (rows.isEmpty) return;
    final repayment = LoanRepayment.fromMap(rows.first);
    final loanRows = await database.query('loans', where: 'id = ?', whereArgs: [repayment.loanId], limit: 1);
    if (loanRows.isEmpty) return;
    final loan = Loan.fromMap(loanRows.first);
    final repaid = math.max<double>(0.0, loan.repaidAmount - repayment.amount);
    await database.transaction((txn) async {
      await _applyLoanRepayment(txn, loan, repayment, -1);
      await txn.update('loans', loan.copyWith(repaidAmount: repaid, status: repaid >= loan.amount ? LoanStatus.completed : LoanStatus.open, updatedOn: DateTime.now()).toMap(), where: 'id = ?', whereArgs: [loan.id]);
      await txn.delete('transactions', where: 'repayment_id = ?', whereArgs: [repaymentId]);
      await txn.delete('loan_repayments', where: 'id = ?', whereArgs: [repaymentId]);
    });
  }

  Future<Map<String, dynamic>> exportAll() async {
    final database = await db;
    final tables = ['accounts', 'categories', 'transactions', 'budgets', 'budget_accounts', 'budget_categories', 'loans', 'loan_repayments', 'loan_repayment_reminders'];
    final data = <String, dynamic>{};
    for (final table in tables) {
      data[table] = await database.query(table);
    }
    return data;
  }

  Future<void> importAll(Map<String, dynamic> data) async {
    final database = await db;
    final tables = ['loan_repayment_reminders', 'loan_repayments', 'loans', 'budget_categories', 'budget_accounts', 'budgets', 'transactions', 'categories', 'accounts'];
    await database.transaction((txn) async {
      for (final table in tables) {
        await txn.delete(table);
      }
      for (final table in tables.reversed) {
        final rows = (data[table] as List? ?? []).cast<Map>();
        for (final row in rows) {
          await txn.insert(table, row.cast<String, Object?>(), conflictAlgorithm: sql.ConflictAlgorithm.replace);
        }
      }
    });
    await _migrateLoanAccountSelection(database);
  }
}

class PrefsStore {
  SharedPreferences? _prefs;
  Future<SharedPreferences> get prefs async => _prefs ??= await SharedPreferences.getInstance();

  Future<T> getEnum<T>(String key, Iterable<T> values, T fallback) async => enumByName(values, (await prefs).getString(key), fallback);
  Future<void> setEnum(String key, Object value) async => (await prefs).setString(key, enumName(value));
  Future<bool> getBool(String key, bool fallback) async => (await prefs).getBool(key) ?? fallback;
  Future<void> setBool(String key, bool value) async => (await prefs).setBool(key, value);
  Future<String> getString(String key, String fallback) async => (await prefs).getString(key) ?? fallback;
  Future<void> setString(String key, String value) async => (await prefs).setString(key, value);
  Future<int> getInt(String key, int fallback) async => (await prefs).getInt(key) ?? fallback;
  Future<void> setInt(String key, int value) async => (await prefs).setInt(key, value);
  Future<List<String>> getStringList(String key) async => (await prefs).getStringList(key) ?? const [];
  Future<void> setStringList(String key, List<String> value) async => (await prefs).setStringList(key, value);
}

class SecureCredentialStore {
  SecureCredentialStore() : _storage = const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _cloudSyncPinKey = 'koinly_cloud_sync_pin';
  static const _mongoUrlKey = 'koinly_sync_mongodb_url';
  static const _mongoSyncPinKey = 'koinly_sync_mongodb_pin';
  static const _tursoAuthTokenKey = 'koinly_sync_turso_auth_token';

  Future<String> readCloudSyncPin() async => await _storage.read(key: _cloudSyncPinKey) ?? '';
  Future<void> writeCloudSyncPin(String value) => _writeOrDelete(_cloudSyncPinKey, value);

  Future<String> readMongoDbUrl() async => await _storage.read(key: _mongoUrlKey) ?? '';
  Future<void> writeMongoDbUrl(String value) => _writeOrDelete(_mongoUrlKey, value);

  Future<String> readMongoDbSyncPin() async => await _storage.read(key: _mongoSyncPinKey) ?? '';
  Future<void> writeMongoDbSyncPin(String value) => _writeOrDelete(_mongoSyncPinKey, value);

  Future<String> readTursoAuthToken() async => await _storage.read(key: _tursoAuthTokenKey) ?? '';
  Future<void> writeTursoAuthToken(String value) => _writeOrDelete(_tursoAuthTokenKey, value);

  Future<void> _writeOrDelete(String key, String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      await _storage.delete(key: key);
    } else {
      await _storage.write(key: key, value: normalized);
    }
  }
}


class ReminderService {
  static final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();

  static Future<void> ensureInitialized() async {
    if (!kSupportsLocalNotifications) return;
    tzdata.initializeTimeZones();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    await _notifications.initialize(settings);
    final androidPlugin = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestNotificationsPermission();
  }

  static Future<void> scheduleDaily(TimeOfDay time) async {
    if (!kSupportsLocalNotifications) return;
    await cancel();
    final scheduled = _next(time);
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'daily_expense_reminder',
        'Daily expense reminder',
        channelDescription: 'Reminder to add daily expenses.',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
    await _notifications.zonedSchedule(
      501,
      'Koinly',
      "Don’t forget to record your expenses",
      scheduled,
      details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  static tz.TZDateTime _next(TimeOfDay time) {
    final now = tz.TZDateTime.now(tz.local);
    var date = tz.TZDateTime(tz.local, now.year, now.month, now.day, time.hour, time.minute);
    if (date.isBefore(now)) date = date.add(const Duration(days: 1));
    return date;
  }


  static int _loanReminderNotificationId(String id) => 700000 + (id.hashCode.abs() % 200000);

  static Future<void> scheduleLoanRepaymentReminder({required Loan loan, required LoanRepaymentReminder reminder}) async {
    if (!kSupportsLocalNotifications || reminder.isPaid) return;
    final scheduled = tz.TZDateTime.from(reminder.reminderAt, tz.local);
    if (scheduled.isBefore(tz.TZDateTime.now(tz.local))) return;
    final label = loan.type == LoanType.given ? 'Loan repayment expected' : 'Loan repayment due';
    final body = loan.type == LoanType.given
        ? 'Expected repayment from ${loan.personName} is due on ${DateFormat('MMM d, yyyy').format(reminder.dueDate)}.'
        : 'Repayment to ${loan.personName} is due on ${DateFormat('MMM d, yyyy').format(reminder.dueDate)}.';
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'loan_repayment_reminders',
        'Loan repayment reminders',
        channelDescription: 'Upcoming, due today, and overdue loan repayment alerts.',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
    await _notifications.zonedSchedule(
      _loanReminderNotificationId(reminder.id),
      label,
      body,
      scheduled,
      details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  static Future<void> cancelLoanRepaymentReminder(String id) async {
    if (!kSupportsLocalNotifications) return;
    await _notifications.cancel(_loanReminderNotificationId(id));
  }

  static Future<void> cancel() async {
    if (!kSupportsLocalNotifications) return;
    await _notifications.cancel(501);
  }
}

class ExportService {
  static Future<void> exportCsv(AppController state, List<MoneyTransaction> txs) async {
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'koinly_export_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.csv'));
    final buffer = StringBuffer();
    final summary = state.summaryFor(txs);
    buffer.writeln('Export date,${DateTime.now().toIso8601String()}');
    buffer.writeln('Total transactions,${txs.length}');
    buffer.writeln('Total income,${summary.income}');
    buffer.writeln('Total expense,${summary.expense}');
    buffer.writeln('Net balance,${summary.balance}');
    buffer.writeln();
    buffer.writeln('Date,Time,Transaction type,Category,Category type,From account,Account type,To account,Amount,Notes');
    for (final tx in txs) {
      final category = state.categoryOf(tx.categoryId);
      final from = state.accountOf(tx.fromAccountId);
      final to = tx.toAccountId == null ? null : state.accountOf(tx.toAccountId!);
      final row = [
        DateFormat('yyyy-MM-dd').format(tx.createdOn),
        DateFormat('HH:mm').format(tx.createdOn),
        tx.displayType,
        category?.name ?? '',
        tx.isLoanMovement ? 'loan' : (category == null ? '' : enumName(category.type)),
        from?.name ?? '',
        from == null ? '' : enumName(from.type),
        to?.name ?? '',
        tx.amount.toStringAsFixed(2),
        tx.notes.replaceAll('\n', ' '),
      ];
      buffer.writeln(row.map(_csvEscape).join(','));
    }
    await file.writeAsString(buffer.toString());
    await Share.shareXFiles([XFile(file.path)], text: 'Koinly CSV export');
  }

  static String _csvEscape(String input) => '"${input.replaceAll('"', '""')}"';

  static Future<void> exportPdf(AppController state, List<MoneyTransaction> txs) async {
    final pdf = pw.Document();
    final summary = state.summaryFor(txs);
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (context) => [
          pw.Header(level: 0, child: pw.Text('Koinly Export Report')),
          pw.Text('Export date/time: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}'),
          pw.SizedBox(height: 8),
          pw.Text('Total transactions: ${txs.length}'),
          pw.Text('Total income: ${state.format(summary.income)}'),
          pw.Text('Total expense: ${state.format(summary.expense)}'),
          pw.Text('Net balance: ${state.format(summary.balance)}'),
          pw.SizedBox(height: 16),
          pw.Table.fromTextArray(
            headers: const ['Date', 'Type', 'Category', 'From', 'To', 'Amount', 'Notes'],
            data: txs.map((tx) {
              final category = state.categoryOf(tx.categoryId);
              final from = state.accountOf(tx.fromAccountId);
              final to = tx.toAccountId == null ? null : state.accountOf(tx.toAccountId!);
              return [
                DateFormat('yyyy-MM-dd HH:mm').format(tx.createdOn),
                tx.displayType,
                category?.name ?? '',
                from?.name ?? '',
                to?.name ?? '',
                state.format(tx.amount),
                tx.notes,
              ];
            }).toList(),
            cellStyle: const pw.TextStyle(fontSize: 8),
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8),
          ),
        ],
      ),
    );
    await Printing.sharePdf(bytes: await pdf.save(), filename: 'koinly_report.pdf');
  }
}

class BackupService {
  static String _crypt(String source) {
    final key = utf8.encode(backupPassword);
    final bytes = utf8.encode(source);
    final out = List<int>.generate(bytes.length, (i) => bytes[i] ^ key[i % key.length]);
    return base64Encode(out);
  }

  static String _decrypt(String source) {
    final key = utf8.encode(backupPassword);
    final bytes = base64Decode(source);
    final out = List<int>.generate(bytes.length, (i) => bytes[i] ^ key[i % key.length]);
    return utf8.decode(out);
  }

  static String backupFileName() {
    return 'koinly_backup_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.koinlybackup';
  }

  static Future<File> createBackup(AppController state) async {
    final dir = await getTemporaryDirectory();
    final payload = {
      'version': 4,
      'created_at': DateTime.now().toIso8601String(),
      'database': await state.database.exportAll(),
      'preferences': await state.exportPreferences(),
    };
    final file = File(p.join(dir.path, backupFileName()));
    await file.writeAsString(_crypt(jsonEncode(payload)));
    return file;
  }

  static Future<File> saveBackupToAppStorage(File source, {String? fileName}) async {
    final dir = await getApplicationDocumentsDirectory();
    final backupsDir = Directory(p.join(dir.path, 'backups'));
    if (!await backupsDir.exists()) {
      await backupsDir.create(recursive: true);
    }
    final target = File(p.join(backupsDir.path, fileName ?? p.basename(source.path)));
    return source.copy(target.path);
  }

  static Future<void> restoreBackup(AppController state) async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.any);
    if (picked == null || picked.files.single.path == null) return;
    final encrypted = await File(picked.files.single.path!).readAsString();
    final payload = jsonDecode(_decrypt(encrypted)) as Map<String, dynamic>;
    await state.database.importAll((payload['database'] as Map).cast<String, dynamic>());
    await state.importPreferences((payload['preferences'] as Map? ?? {}).cast<String, dynamic>());
    await state.reload();
  }
}

class CloudSyncException implements Exception {
  const CloudSyncException(this.message, {this.code});

  final String message;
  final String? code;

  bool get approvalRequired => code == 'SYNC_APPROVAL_REQUIRED';

  @override
  String toString() => message;
}

class CloudSyncService {
  static const int payloadVersion = 5;
  static const String defaultApiBaseUrl = String.fromEnvironment(
    'KOINLY_SYNC_API_BASE_URL',
    defaultValue: '',
  );

  static String get configuredApiBaseUrl => resolveApiBaseUrl(defaultApiBaseUrl);

  static String normalizeSyncId(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_.-]'), '-').replaceAll(RegExp(r'-+'), '-');
  }

  static String normalizeApiBaseUrl(String value) {
    var normalized = value.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  static String resolveApiBaseUrl([String? savedValue]) {
    final fromBuild = normalizeApiBaseUrl(defaultApiBaseUrl);
    if (fromBuild.isNotEmpty) return fromBuild;
    return normalizeApiBaseUrl(savedValue ?? '');
  }

  static Future<void> upload({
    required String apiBaseUrl,
    required String syncId,
    required String pin,
    required Map<String, dynamic> payload,
  }) async {
    await _post(
      apiBaseUrl: apiBaseUrl,
      path: '/api/sync/push',
      body: {
        'syncId': normalizeSyncId(syncId),
        'pin': pin.trim(),
        'payload': payload,
        'deviceId': Platform.localHostname,
        'clientUpdatedAt': DateTime.now().toUtc().toIso8601String(),
      },
    );
  }

  static Future<Map<String, dynamic>> download({
    required String apiBaseUrl,
    required String syncId,
    required String pin,
  }) async {
    final data = await _post(
      apiBaseUrl: apiBaseUrl,
      path: '/api/sync/pull',
      body: {
        'syncId': normalizeSyncId(syncId),
        'pin': pin.trim(),
        'deviceId': Platform.localHostname,
      },
    );
    final payload = data['payload'];
    if (payload is! Map) {
      throw StateError('Cloud data is missing or damaged.');
    }
    return payload.cast<String, dynamic>();
  }

  static Future<void> testBackend(String apiBaseUrl) async {
    final baseUrl = resolveApiBaseUrl(apiBaseUrl);
    if (baseUrl.isEmpty || baseUrl.contains('your-koinly-sync-worker')) {
      throw StateError('Add the Worker API URL first.');
    }
    final response = await http
        .get(
          Uri.parse(baseUrl),
          headers: const {'accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 18));
    if (response.statusCode >= 500) {
      throw StateError('Sync backend is reachable but returned a server error.');
    }
  }

  static Future<Map<String, dynamic>> _post({
    required String apiBaseUrl,
    required String path,
    required Map<String, dynamic> body,
  }) async {
    final baseUrl = resolveApiBaseUrl(apiBaseUrl);
    if (baseUrl.isEmpty || baseUrl.contains('your-koinly-sync-worker')) {
      throw StateError('Cloud sync backend URL is not configured in this APK. Rebuild with --dart-define=KOINLY_SYNC_API_BASE_URL=https://your-worker.workers.dev.');
    }
    final uri = Uri.parse('$baseUrl$path');
    final response = await http
        .post(
          uri,
          headers: const {
            'content-type': 'application/json',
            'accept': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 25));

    final decoded = response.body.trim().isEmpty ? <String, dynamic>{} : jsonDecode(response.body);
    final data = decoded is Map ? decoded.cast<String, dynamic>() : <String, dynamic>{};
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CloudSyncException(
        data['error']?.toString() ?? 'Sync request failed (${response.statusCode}).',
        code: data['code']?.toString(),
      );
    }
    return data;
  }
}

class MongoDbSyncService {
  static const String defaultDatabaseName = 'koinly';
  static const String defaultCollectionName = 'koinly_sync_snapshots';
  static const String snapshotDocumentId = 'koinly_latest_snapshot';

  static String normalizeDatabaseName(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return defaultDatabaseName;
    return normalized.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
  }

  static String normalizeCollectionName(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return defaultCollectionName;
    return normalized.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
  }

  static Future<void> testConnection({
    required String connectionString,
    required String databaseName,
    required String collectionName,
  }) async {
    final db = await _open(connectionString, databaseName);
    try {
      final collection = db.collection(normalizeCollectionName(collectionName));
      await collection.findOne(mongo.where.eq('_id', '__koinly_connection_test__')).timeout(const Duration(seconds: 20));
    } finally {
      await db.close();
    }
  }

  static Future<void> upload({
    required String connectionString,
    required String databaseName,
    required String collectionName,
    required Map<String, dynamic> payload,
  }) async {
    final db = await _open(connectionString, databaseName);
    try {
      final collection = db.collection(normalizeCollectionName(collectionName));
      final now = DateTime.now().toUtc().toIso8601String();
      await collection.replaceOne(
        mongo.where.eq('_id', snapshotDocumentId),
        <String, dynamic>{
          '_id': snapshotDocumentId,
          'payloadVersion': CloudSyncService.payloadVersion,
          'payload': payload,
          'deviceId': Platform.localHostname,
          'updatedAt': now,
        },
        upsert: true,
      ).timeout(const Duration(seconds: 28));
    } finally {
      await db.close();
    }
  }

  static Future<Map<String, dynamic>> download({
    required String connectionString,
    required String databaseName,
    required String collectionName,
  }) async {
    final db = await _open(connectionString, databaseName);
    try {
      final collection = db.collection(normalizeCollectionName(collectionName));
      final document = await collection.findOne(mongo.where.eq('_id', snapshotDocumentId)).timeout(const Duration(seconds: 28));
      if (document == null) {
        throw StateError('No MongoDB sync snapshot exists yet. Upload local data first.');
      }
      final payload = document['payload'];
      if (payload is! Map) {
        throw StateError('MongoDB sync data is missing or damaged.');
      }
      final normalizedPayload = _normalizeBsonValue(payload);
      if (normalizedPayload is! Map) {
        throw StateError('MongoDB sync data is missing or damaged.');
      }
      return normalizedPayload.cast<String, dynamic>();
    } finally {
      await db.close();
    }
  }

  static dynamic _normalizeBsonValue(dynamic value) {
    if (value == null || value is String || value is bool || value is num) {
      return value;
    }
    if (value is DateTime) {
      return value.toIso8601String();
    }
    if (value is List) {
      return value.map(_normalizeBsonValue).toList();
    }
    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), _normalizeBsonValue(item)));
    }

    final typeName = value.runtimeType.toString();
    if (typeName == 'Int64' || typeName.endsWith('.Int64')) {
      return int.tryParse(value.toString()) ?? double.tryParse(value.toString()) ?? value.toString();
    }
    return value.toString();
  }

  static Future<mongo.Db> _open(String connectionString, String databaseName) async {
    final normalized = connectionString.trim();
    if (normalized.isEmpty) {
      throw StateError('Add your MongoDB URL first.');
    }
    if (!normalized.startsWith('mongodb://') && !normalized.startsWith('mongodb+srv://')) {
      throw StateError('MongoDB URL must start with mongodb:// or mongodb+srv://.');
    }
    final resolvedUri = _withDatabaseName(normalized, normalizeDatabaseName(databaseName));
    final db = await mongo.Db.create(resolvedUri);
    await db.open().timeout(const Duration(seconds: 22));
    return db;
  }

  static String _withDatabaseName(String uri, String databaseName) {
    final queryIndex = uri.indexOf('?');
    final beforeQuery = queryIndex == -1 ? uri : uri.substring(0, queryIndex);
    final query = queryIndex == -1 ? '' : uri.substring(queryIndex);
    final schemeIndex = beforeQuery.indexOf('://');
    if (schemeIndex == -1) return uri;
    final hostStart = schemeIndex + 3;
    final slashIndex = beforeQuery.indexOf('/', hostStart);
    if (slashIndex == -1) {
      return '$beforeQuery/$databaseName$query';
    }
    final path = beforeQuery.substring(slashIndex + 1).trim();
    if (path.isEmpty) {
      return '${beforeQuery.substring(0, slashIndex)}/$databaseName$query';
    }
    return uri;
  }

}

Future<void> runBackupFlow(BuildContext context, AppController state) async {
  try {
    final tempFile = await BackupService.createBackup(state);
    final fileName = p.basename(tempFile.path);
    final fileBytes = await tempFile.readAsBytes();

    String? savedPath;
    try {
      savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Koinly backup',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: const ['koinlybackup'],
        bytes: fileBytes,
      );
    } catch (_) {
      savedPath = null;
    }

    final localFile = await BackupService.saveBackupToAppStorage(tempFile, fileName: fileName);

    if (context.mounted) {
      if (savedPath == null) {
        showSnack(context, 'Backup saved to local app storage.');
      } else {
        showSnack(context, 'Backup saved to local storage.');
      }
    }

    if (localFile.path.isEmpty) {
      throw const FileSystemException('Backup file was not saved.');
    }
  } catch (_) {
    if (context.mounted) {
      showSnack(context, 'Backup failed. Please try again.');
    }
  }
}

Future<void> runRestoreFlow(BuildContext context, AppController state) async {
  try {
    await BackupService.restoreBackup(state);
    if (context.mounted) {
      showSnack(context, 'Restore complete. Restart the app if any screen looks stale.');
    }
  } catch (_) {
    if (context.mounted) {
      showSnack(context, 'Restore failed. Please check the backup file.');
    }
  }
}


// -----------------------------------------------------------------------------
// Controller
// -----------------------------------------------------------------------------

class AppController extends ChangeNotifier {
  final database = KoinlyDatabase();
  final prefs = PrefsStore();
  final secureCredentials = SecureCredentialStore();

  bool loading = true;
  bool onboardingCompleted = false;
  int desktopSetupVersionCompleted = 0;
  bool authenticated = false;
  int tabIndex = 0;
  LoanType activeLoanType = LoanType.given;

  List<Account> accounts = [];
  List<Category> categories = [];
  List<MoneyTransaction> transactions = [];
  List<Budget> budgets = [];
  List<Loan> loans = [];
  List<LoanRepaymentReminder> loanRepaymentReminders = [];
  SavingsSuggestionProfile savingsSuggestionProfile = SavingsSuggestionProfile.empty;
  List<String> savedSavingsIdeas = [];
  List<String> plannedSavingsIdeas = [];
  List<String> seenSavingsSuggestionKeys = [];
  List<String> dismissedFinancialHealthSummaryKeys = [];

  ThemePreference themePreference = ThemePreference.system;
  String currencySymbol = '৳';
  String currencyCode = 'BDT';
  CurrencyPosition currencyPosition = CurrencyPosition.suffix;
  bool useSeparators = true;
  bool amountsHidden = false;
  DateRangeType dateRangeType = DateRangeType.thisMonth;
  DateTime? customStart;
  DateTime? customEnd;
  List<String> filterAccountIds = [];
  List<String> filterCategoryIds = [];
  List<MoneyTransactionType> filterTypes = [];
  String? defaultAccountId;
  String? defaultExpenseCategoryId;
  String? defaultIncomeCategoryId;
  bool compactHomeSummary = false;
  bool appLockEnabled = false;
  bool reminderEnabled = false;
  TimeOfDay reminderTime = const TimeOfDay(hour: 21, minute: 0);
  bool cloudSyncEnabled = false;
  SyncDatabaseProvider syncDatabaseProvider = SyncDatabaseProvider.mongoDb;
  String cloudSyncApiBaseUrl = CloudSyncService.configuredApiBaseUrl;
  String cloudSyncId = '';
  String cloudSyncPin = '';
  String syncMongoDbUrl = '';
  String syncMongoDatabaseName = MongoDbSyncService.defaultDatabaseName;
  String syncMongoCollectionName = MongoDbSyncService.defaultCollectionName;
  String syncMongoSyncId = '';
  String syncMongoSyncPin = '';
  String syncTursoDatabaseUrl = '';
  String syncTursoAuthToken = '';
  bool cloudSyncBusy = false;
  bool cloudSyncPending = false;
  String? cloudSyncError;
  String? cloudSyncErrorCode;
  DateTime? cloudSyncLastAt;
  Timer? _cloudSyncDebounce;
  Timer? _cloudSyncRetryTimer;

  bool get setupCompletedForCurrentPlatform {
    if (!onboardingCompleted) return false;
    if (!kIsDesktopApp) return true;
    return desktopSetupVersionCompleted >= kRequiredDesktopSetupVersion;
  }

  Future<void> initialize() async {
    await database.db;
    await _loadPreferences();
    await reload();
    loading = false;
    if (appLockEnabled) {
      authenticated = await authenticate();
    } else {
      authenticated = true;
    }
    notifyListeners();
    try {
      await FirebaseAnalytics.instance.logAppOpen();
    } catch (_) {}
    if (cloudSyncPending) {
      _schedulePendingSyncRetry(immediate: true);
    }
  }

  Future<void> _loadPreferences() async {
    onboardingCompleted = await prefs.getBool('onboardingCompleted', false);
    desktopSetupVersionCompleted = await prefs.getInt('desktopSetupVersionCompleted', 0);
    themePreference = await prefs.getEnum('themePreference', ThemePreference.values, ThemePreference.system);
    currencySymbol = await prefs.getString('currencySymbol', '৳');
    currencyCode = await prefs.getString('currencyCode', 'BDT');
    currencyPosition = await prefs.getEnum('currencyPosition', CurrencyPosition.values, CurrencyPosition.suffix);
    useSeparators = await prefs.getBool('useSeparators', true);
    amountsHidden = await prefs.getBool('amountsHidden', false);
    savingsSuggestionProfile = SavingsSuggestionProfile.fromJsonString(await prefs.getString('savingsSuggestionProfile', ''));
    savedSavingsIdeas = await prefs.getStringList('savedSavingsIdeas');
    plannedSavingsIdeas = await prefs.getStringList('plannedSavingsIdeas');
    seenSavingsSuggestionKeys = await prefs.getStringList('seenSavingsSuggestionKeys');
    dismissedFinancialHealthSummaryKeys = await prefs.getStringList('dismissedFinancialHealthSummaryKeys');
    dateRangeType = await prefs.getEnum('dateRangeType', DateRangeType.values, DateRangeType.thisMonth);
    final startRaw = await prefs.getString('customStart', '');
    final endRaw = await prefs.getString('customEnd', '');
    customStart = startRaw.isEmpty ? null : DateTime.tryParse(startRaw);
    customEnd = endRaw.isEmpty ? null : DateTime.tryParse(endRaw);
    filterAccountIds = await prefs.getStringList('filterAccountIds');
    filterCategoryIds = await prefs.getStringList('filterCategoryIds');
    filterTypes = (await prefs.getStringList('filterTypes')).map((e) => enumByName(MoneyTransactionType.values, e, MoneyTransactionType.expense)).toList();
    defaultAccountId = await prefs.getString('defaultAccountId', '');
    if (defaultAccountId?.isEmpty == true) defaultAccountId = null;
    defaultExpenseCategoryId = await prefs.getString('defaultExpenseCategoryId', '');
    if (defaultExpenseCategoryId?.isEmpty == true) defaultExpenseCategoryId = null;
    defaultIncomeCategoryId = await prefs.getString('defaultIncomeCategoryId', '');
    if (defaultIncomeCategoryId?.isEmpty == true) defaultIncomeCategoryId = null;
    compactHomeSummary = await prefs.getBool('compactHomeSummary', false);
    appLockEnabled = await prefs.getBool('appLockEnabled', false);
    reminderEnabled = await prefs.getBool('reminderEnabled', false);
    final hour = await prefs.getInt('reminderHour', 21);
    final minute = await prefs.getInt('reminderMinute', 0);
    reminderTime = TimeOfDay(hour: hour, minute: minute);
    cloudSyncEnabled = await prefs.getBool('cloudSyncEnabled', true);
    syncDatabaseProvider = await prefs.getEnum('syncDatabaseProvider', SyncDatabaseProvider.values, SyncDatabaseProvider.mongoDb);
    if (!userSyncDatabaseProviders.contains(syncDatabaseProvider)) {
      syncDatabaseProvider = SyncDatabaseProvider.mongoDb;
      cloudSyncEnabled = true;
      await prefs.setEnum('syncDatabaseProvider', SyncDatabaseProvider.mongoDb);
      await prefs.setBool('cloudSyncEnabled', true);
    }
    final savedCloudSyncApiBaseUrl = await prefs.getString('cloudSyncApiBaseUrl', '');
    cloudSyncApiBaseUrl = CloudSyncService.resolveApiBaseUrl(savedCloudSyncApiBaseUrl);
    cloudSyncId = await prefs.getString('cloudSyncId', '');
    cloudSyncPin = await secureCredentials.readCloudSyncPin();
    final legacyPin = await prefs.getString('cloudSyncPin', '');
    if (cloudSyncPin.isEmpty && legacyPin.trim().isNotEmpty) {
      cloudSyncPin = legacyPin.trim();
      await secureCredentials.writeCloudSyncPin(cloudSyncPin);
      await (await prefs.prefs).remove('cloudSyncPin');
    }
    syncMongoDbUrl = await secureCredentials.readMongoDbUrl();
    syncMongoDatabaseName = MongoDbSyncService.normalizeDatabaseName(await prefs.getString('syncMongoDatabaseName', MongoDbSyncService.defaultDatabaseName));
    syncMongoCollectionName = MongoDbSyncService.normalizeCollectionName(await prefs.getString('syncMongoCollectionName', MongoDbSyncService.defaultCollectionName));
    syncMongoSyncId = CloudSyncService.normalizeSyncId(await prefs.getString('syncMongoSyncId', ''));
    syncMongoSyncPin = await secureCredentials.readMongoDbSyncPin();
    syncTursoDatabaseUrl = await prefs.getString('syncTursoDatabaseUrl', '');
    syncTursoAuthToken = await secureCredentials.readTursoAuthToken();
    if (syncDatabaseProvider == SyncDatabaseProvider.local) {
      cloudSyncEnabled = false;
    } else {
      cloudSyncEnabled = true;
    }
    final lastSyncRaw = await prefs.getString('cloudSyncLastAt', '');
    cloudSyncLastAt = lastSyncRaw.isEmpty ? null : DateTime.tryParse(lastSyncRaw);
    cloudSyncPending = await prefs.getBool('cloudSyncPending', false);
  }

  Future<Map<String, dynamic>> exportPreferences() async => {
        'onboardingCompleted': onboardingCompleted,
        'desktopSetupVersionCompleted': desktopSetupVersionCompleted,
        'themePreference': enumName(themePreference),
        'currencySymbol': currencySymbol,
        'currencyCode': currencyCode,
        'currencyPosition': enumName(currencyPosition),
        'useSeparators': useSeparators,
        'amountsHidden': amountsHidden,
        'savingsSuggestionProfile': savingsSuggestionProfile.toJson(),
        'savedSavingsIdeas': savedSavingsIdeas,
        'plannedSavingsIdeas': plannedSavingsIdeas,
        'seenSavingsSuggestionKeys': seenSavingsSuggestionKeys,
        'dismissedFinancialHealthSummaryKeys': dismissedFinancialHealthSummaryKeys,
        'dateRangeType': enumName(dateRangeType),
        'customStart': customStart?.toIso8601String() ?? '',
        'customEnd': customEnd?.toIso8601String() ?? '',
        'filterAccountIds': filterAccountIds,
        'filterCategoryIds': filterCategoryIds,
        'filterTypes': filterTypes.map(enumName).toList(),
        'defaultAccountId': defaultAccountId ?? '',
        'defaultExpenseCategoryId': defaultExpenseCategoryId ?? '',
        'defaultIncomeCategoryId': defaultIncomeCategoryId ?? '',
        'compactHomeSummary': compactHomeSummary,
        'appLockEnabled': appLockEnabled,
        'reminderEnabled': reminderEnabled,
        'reminderHour': reminderTime.hour,
        'reminderMinute': reminderTime.minute,
        'syncDatabaseProvider': enumName(syncDatabaseProvider),
        'syncMongoDatabaseName': syncMongoDatabaseName,
        'syncMongoCollectionName': syncMongoCollectionName,
      };

  Future<void> importPreferences(Map<String, dynamic> data) async {
    final sp = await prefs.prefs;
    for (final entry in data.entries) {
      final value = entry.value;
      if (entry.key == 'savingsSuggestionProfile' && value is Map) {
        await sp.setString(entry.key, jsonEncode(value.cast<String, dynamic>()));
        continue;
      }
      if (value is bool) await sp.setBool(entry.key, value);
      if (value is int) await sp.setInt(entry.key, value);
      if (value is String) await sp.setString(entry.key, value);
      if (value is List) await sp.setStringList(entry.key, value.map((e) => '$e').toList());
    }
    await _loadPreferences();
  }

  Future<Map<String, dynamic>> exportCloudPayload() async => {
        'version': CloudSyncService.payloadVersion,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'database': await database.exportAll(),
        'preferences': await exportPreferences(),
      };

  String get cloudSyncStatusText {
    if (cloudSyncBusy) return 'Online sync • Syncing...';
    if (cloudSyncPending) return 'Online sync • Waiting for internet';
    if (cloudSyncErrorCode == 'SYNC_APPROVAL_REQUIRED') return 'Online sync • Admin approval required';
    if (cloudSyncError != null && cloudSyncError!.trim().isNotEmpty) return 'Online sync • Error: $cloudSyncError';
    if (!cloudSyncEnabled) return 'Online sync • Waiting for database setup';
    if (cloudSyncLastAt == null) return 'Online sync • Enabled • Not synced yet';
    return 'Online sync • Last sync ${DateFormat('yyyy-MM-dd HH:mm').format(cloudSyncLastAt!.toLocal())}';
  }

  bool get cloudSyncApprovalRequired => cloudSyncErrorCode == 'SYNC_APPROVAL_REQUIRED';

  Future<void> configureCloudSync({required bool enabled, required String apiBaseUrl, required String syncId, required String pin}) async {
    // Automatic sync is always on once an online sync method is configured.
    cloudSyncEnabled = true;
    cloudSyncApiBaseUrl = CloudSyncService.resolveApiBaseUrl(apiBaseUrl);
    cloudSyncId = CloudSyncService.normalizeSyncId(syncId);
    cloudSyncPin = pin.trim();
    cloudSyncError = null;
    cloudSyncErrorCode = null;
    await prefs.setBool('cloudSyncEnabled', cloudSyncEnabled);
    await prefs.setString('cloudSyncApiBaseUrl', cloudSyncApiBaseUrl);
    await prefs.setString('cloudSyncId', cloudSyncId);
    await secureCredentials.writeCloudSyncPin(cloudSyncPin);
    await (await prefs.prefs).remove('cloudSyncPin');
    notifyListeners();
  }

  Future<void> ensureCloudSyncCredentials() async {
    var changed = false;
    if (cloudSyncId.trim().isEmpty) {
      final shortId = _uuid.v4().split('-').first.toLowerCase();
      cloudSyncId = CloudSyncService.normalizeSyncId('koinly-$shortId');
      changed = true;
    }
    if (cloudSyncPin.trim().isEmpty) {
      cloudSyncPin = _uuid.v4().replaceAll('-', '').substring(0, 8);
      changed = true;
    }
    if (!changed) return;
    await prefs.setString('cloudSyncId', cloudSyncId);
    await secureCredentials.writeCloudSyncPin(cloudSyncPin);
    await (await prefs.prefs).remove('cloudSyncPin');
    notifyListeners();
  }

  Future<void> ensureMongoDbSyncCredentials() async {
    var changed = false;
    if (syncMongoSyncId.trim().isEmpty) {
      final shortId = _uuid.v4().split('-').first.toLowerCase();
      syncMongoSyncId = CloudSyncService.normalizeSyncId('mongo-$shortId');
      changed = true;
    }
    if (syncMongoSyncPin.trim().isEmpty) {
      syncMongoSyncPin = _uuid.v4().replaceAll('-', '').substring(0, 8);
      changed = true;
    }
    if (!changed) return;
    notifyListeners();
  }

  Future<void> configureSyncDatabase({
    required SyncDatabaseProvider provider,
    required String apiBaseUrl,
    required String mongoDbUrl,
    required String mongoDatabaseName,
    required String mongoCollectionName,
    required String tursoDatabaseUrl,
    required String tursoAuthToken,
  }) async {
    provider = userSyncDatabaseProviders.contains(provider) ? provider : SyncDatabaseProvider.mongoDb;
    syncDatabaseProvider = provider;
    cloudSyncApiBaseUrl = CloudSyncService.resolveApiBaseUrl(apiBaseUrl);
    syncMongoDbUrl = mongoDbUrl.trim();
    syncMongoDatabaseName = MongoDbSyncService.normalizeDatabaseName(mongoDatabaseName);
    syncMongoCollectionName = MongoDbSyncService.normalizeCollectionName(mongoCollectionName);
    syncTursoDatabaseUrl = tursoDatabaseUrl.trim();
    syncTursoAuthToken = tursoAuthToken.trim();
    cloudSyncError = null;
    cloudSyncErrorCode = null;
    if (provider == SyncDatabaseProvider.local) {
      cloudSyncEnabled = false;
      cloudSyncLastAt = null;
      await prefs.setBool('cloudSyncEnabled', false);
    } else {
      cloudSyncEnabled = true;
      await prefs.setBool('cloudSyncEnabled', true);
    }
    await prefs.setEnum('syncDatabaseProvider', provider);
    await prefs.setString('cloudSyncApiBaseUrl', cloudSyncApiBaseUrl);
    await prefs.setString('syncMongoDatabaseName', syncMongoDatabaseName);
    await prefs.setString('syncMongoCollectionName', syncMongoCollectionName);
    await prefs.setString('syncTursoDatabaseUrl', syncTursoDatabaseUrl);
    await secureCredentials.writeMongoDbUrl(syncMongoDbUrl);
    await secureCredentials.writeTursoAuthToken(syncTursoAuthToken);
    if (cloudSyncPending) _schedulePendingSyncRetry(immediate: true);
    notifyListeners();
  }

  Future<void> testSyncDatabaseConnection({
    SyncDatabaseProvider? provider,
    String? apiBaseUrl,
    String? mongoDbUrl,
    String? mongoDatabaseName,
    String? mongoCollectionName,
  }) async {
    final resolvedProvider = provider ?? syncDatabaseProvider;
    switch (resolvedProvider) {
      case SyncDatabaseProvider.local:
        return;
      case SyncDatabaseProvider.turso:
      case SyncDatabaseProvider.cloudflareD1:
      case SyncDatabaseProvider.supabase:
      case SyncDatabaseProvider.neonPostgres:
      case SyncDatabaseProvider.firebaseFirestore:
        await CloudSyncService.testBackend(apiBaseUrl ?? cloudSyncApiBaseUrl);
        return;
      case SyncDatabaseProvider.mongoDb:
        await MongoDbSyncService.testConnection(
          connectionString: mongoDbUrl ?? syncMongoDbUrl,
          databaseName: mongoDatabaseName ?? syncMongoDatabaseName,
          collectionName: mongoCollectionName ?? syncMongoCollectionName,
        );
        return;
    }
  }

  Future<void> syncMainOnlineToCloud({bool force = false}) async {
    if (cloudSyncBusy) return;
    if (cloudSyncId.trim().isEmpty || cloudSyncPin.trim().isEmpty) {
      await ensureCloudSyncCredentials();
    }
    cloudSyncBusy = true;
    cloudSyncError = null;
    cloudSyncErrorCode = null;
    notifyListeners();
    try {
      final payload = await exportCloudPayload();
      await CloudSyncService.upload(apiBaseUrl: cloudSyncApiBaseUrl, syncId: cloudSyncId, pin: cloudSyncPin, payload: payload);
      cloudSyncLastAt = DateTime.now();
      await prefs.setString('cloudSyncLastAt', cloudSyncLastAt!.toIso8601String());
    } catch (error) {
      cloudSyncError = _cleanSyncError(error);
      cloudSyncErrorCode = error is CloudSyncException ? error.code : null;
    } finally {
      cloudSyncBusy = false;
      notifyListeners();
    }
  }

  Future<void> syncMainOnlineFromCloud() async {
    if (cloudSyncBusy) return;
    if (cloudSyncId.trim().isEmpty || cloudSyncPin.trim().isEmpty) {
      cloudSyncError = 'Enter a Sync ID and PIN on the main Online data sync page, or upload first to create them.';
      notifyListeners();
      return;
    }
    cloudSyncBusy = true;
    cloudSyncError = null;
    cloudSyncErrorCode = null;
    notifyListeners();
    try {
      final payload = await CloudSyncService.download(apiBaseUrl: cloudSyncApiBaseUrl, syncId: cloudSyncId, pin: cloudSyncPin);
      final databasePayload = (payload['database'] as Map? ?? {}).cast<String, dynamic>();
      final preferencesPayload = (payload['preferences'] as Map? ?? {}).cast<String, dynamic>();
      await database.importAll(databasePayload);
      await importPreferences(preferencesPayload);
      cloudSyncEnabled = true;
      await prefs.setBool('cloudSyncEnabled', true);
      await prefs.setString('cloudSyncApiBaseUrl', cloudSyncApiBaseUrl);
      await prefs.setString('cloudSyncId', cloudSyncId);
      await secureCredentials.writeCloudSyncPin(cloudSyncPin);
      await (await prefs.prefs).remove('cloudSyncPin');
      cloudSyncLastAt = DateTime.now();
      await prefs.setString('cloudSyncLastAt', cloudSyncLastAt!.toIso8601String());
      await reload(queueSync: false);
    } catch (error) {
      cloudSyncError = _cleanSyncError(error);
      cloudSyncErrorCode = error is CloudSyncException ? error.code : null;
    } finally {
      cloudSyncBusy = false;
      notifyListeners();
    }
  }

  Future<void> syncToCloud({bool force = false, bool silent = false}) async {
    if (cloudSyncBusy) return;
    if (!_hasConfiguredSyncTarget()) return;
    if (syncDatabaseProvider != SyncDatabaseProvider.mongoDb && (cloudSyncId.trim().isEmpty || cloudSyncPin.trim().isEmpty)) {
      await ensureCloudSyncCredentials();
    }
    cloudSyncBusy = true;
    if (!silent) {
      cloudSyncError = null;
      cloudSyncErrorCode = null;
    }
    notifyListeners();
    try {
      final payload = await exportCloudPayload();
      switch (syncDatabaseProvider) {
        case SyncDatabaseProvider.local:
          break;
        case SyncDatabaseProvider.turso:
        case SyncDatabaseProvider.cloudflareD1:
        case SyncDatabaseProvider.supabase:
        case SyncDatabaseProvider.neonPostgres:
        case SyncDatabaseProvider.firebaseFirestore:
          await CloudSyncService.upload(apiBaseUrl: cloudSyncApiBaseUrl, syncId: cloudSyncId, pin: cloudSyncPin, payload: payload);
          break;
        case SyncDatabaseProvider.mongoDb:
          await MongoDbSyncService.upload(
            connectionString: syncMongoDbUrl,
            databaseName: syncMongoDatabaseName,
            collectionName: syncMongoCollectionName,
            payload: payload,
          );
          break;
      }
      cloudSyncLastAt = DateTime.now();
      await prefs.setString('cloudSyncLastAt', cloudSyncLastAt!.toIso8601String());
      await _setCloudSyncPending(false);
      cloudSyncError = null;
      cloudSyncErrorCode = null;
      _cloudSyncRetryTimer?.cancel();
      _cloudSyncRetryTimer = null;
    } catch (error) {
      await _setCloudSyncPending(true);
      _schedulePendingSyncRetry();
      if (!silent) {
        cloudSyncError = _cleanSyncError(error);
        cloudSyncErrorCode = error is CloudSyncException ? error.code : null;
      } else {
        cloudSyncError = null;
        cloudSyncErrorCode = null;
      }
    } finally {
      cloudSyncBusy = false;
      notifyListeners();
    }
  }

  Future<void> syncFromCloud() async {
    if (cloudSyncBusy) return;
    if (syncDatabaseProvider == SyncDatabaseProvider.local) {
      cloudSyncError = 'Local Database mode is enabled. Choose an online database method to download cloud data.';
      notifyListeners();
      return;
    }
    if (syncDatabaseProvider != SyncDatabaseProvider.mongoDb && (cloudSyncId.trim().isEmpty || cloudSyncPin.trim().isEmpty)) {
      cloudSyncError = 'Upload local data first to create a Sync ID and PIN, or enter an existing Sync ID and PIN.';
      notifyListeners();
      return;
    }
    cloudSyncBusy = true;
    cloudSyncError = null;
    cloudSyncErrorCode = null;
    notifyListeners();
    try {
      late final Map<String, dynamic> payload;
      switch (syncDatabaseProvider) {
        case SyncDatabaseProvider.local:
          payload = <String, dynamic>{};
          break;
        case SyncDatabaseProvider.turso:
        case SyncDatabaseProvider.cloudflareD1:
        case SyncDatabaseProvider.supabase:
        case SyncDatabaseProvider.neonPostgres:
        case SyncDatabaseProvider.firebaseFirestore:
          payload = await CloudSyncService.download(apiBaseUrl: cloudSyncApiBaseUrl, syncId: cloudSyncId, pin: cloudSyncPin);
          break;
        case SyncDatabaseProvider.mongoDb:
          payload = await MongoDbSyncService.download(
            connectionString: syncMongoDbUrl,
            databaseName: syncMongoDatabaseName,
            collectionName: syncMongoCollectionName,
          );
          break;
      }
      final databasePayload = (payload['database'] as Map? ?? {}).cast<String, dynamic>();
      final preferencesPayload = (payload['preferences'] as Map? ?? {}).cast<String, dynamic>();
      await database.importAll(databasePayload);
      await importPreferences(preferencesPayload);
      cloudSyncEnabled = true;
      await prefs.setBool('cloudSyncEnabled', true);
      await prefs.setEnum('syncDatabaseProvider', syncDatabaseProvider);
      await prefs.setString('cloudSyncApiBaseUrl', cloudSyncApiBaseUrl);
      if (syncDatabaseProvider != SyncDatabaseProvider.mongoDb) {
        await prefs.setString('cloudSyncId', cloudSyncId);
        await secureCredentials.writeCloudSyncPin(cloudSyncPin);
        await (await prefs.prefs).remove('cloudSyncPin');
      }
      cloudSyncLastAt = DateTime.now();
      await prefs.setString('cloudSyncLastAt', cloudSyncLastAt!.toIso8601String());
      await reload(queueSync: false);
    } catch (error) {
      cloudSyncError = _cleanSyncError(error);
      cloudSyncErrorCode = error is CloudSyncException ? error.code : null;
    } finally {
      cloudSyncBusy = false;
      notifyListeners();
    }
  }

  bool _hasConfiguredSyncTarget() {
    if (syncDatabaseProvider == SyncDatabaseProvider.local) return false;
    if (syncDatabaseProvider == SyncDatabaseProvider.mongoDb) return syncMongoDbUrl.trim().isNotEmpty;
    return cloudSyncApiBaseUrl.trim().isNotEmpty;
  }

  Future<void> _setCloudSyncPending(bool value) async {
    cloudSyncPending = value;
    await prefs.setBool('cloudSyncPending', value);
  }

  void _schedulePendingSyncRetry({bool immediate = false}) {
    if (!_hasConfiguredSyncTarget()) return;
    if (immediate && cloudSyncPending && !cloudSyncBusy) {
      unawaited(syncToCloud(silent: true));
    }
    _cloudSyncRetryTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
      if (!cloudSyncPending) {
        _cloudSyncRetryTimer?.cancel();
        _cloudSyncRetryTimer = null;
        return;
      }
      if (!cloudSyncBusy && _hasConfiguredSyncTarget()) {
        unawaited(syncToCloud(silent: true));
      }
    });
  }

  void queueCloudSync() {
    if (!_hasConfiguredSyncTarget()) return;
    unawaited(_setCloudSyncPending(true));
    _schedulePendingSyncRetry();
    _cloudSyncDebounce?.cancel();
    _cloudSyncDebounce = Timer(const Duration(seconds: 3), () {
      unawaited(syncToCloud(silent: true));
    });
  }

  String _cleanSyncError(Object error) {
    final text = error.toString().replaceFirst('Exception: ', '').replaceFirst('Bad state: ', '').trim();
    final redacted = redactSyncSecrets(text);
    return redacted.isEmpty ? 'Sync failed. Check your database configuration.' : redacted;
  }

  @override
  void dispose() {
    _cloudSyncDebounce?.cancel();
    _cloudSyncRetryTimer?.cancel();
    super.dispose();
  }

  Future<void> reload({bool queueSync = false}) async {
    accounts = await database.accounts();
    categories = await database.categories();
    transactions = await database.transactions();
    budgets = await database.budgets();
    loans = await database.loans();
    loanRepaymentReminders = await database.loanRepaymentReminders();
    defaultAccountId ??= accounts.where((a) => a.type != AccountType.savings).firstOrNull?.id ?? accounts.firstOrNull?.id;
    defaultExpenseCategoryId ??= categories.where((c) => c.type == CategoryType.expense && !c.isLoanSystemCategory).firstOrNull?.id;
    defaultIncomeCategoryId ??= categories.where((c) => c.type == CategoryType.income && !c.isLoanSystemCategory).firstOrNull?.id;
    notifyListeners();
    if (queueSync) queueCloudSync();
  }

  Future<bool> authenticate() async {
    final auth = LocalAuthentication();
    try {
      final supported = await auth.isDeviceSupported();
      final canCheck = await auth.canCheckBiometrics;
      if (!supported && !canCheck) return true;
      return await auth.authenticate(
        localizedReason: 'Verify your identity to continue',
        options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
      );
    } catch (_) {
      return true;
    }
  }

  ThemeMode get themeMode {
    switch (themePreference) {
      case ThemePreference.light:
        return ThemeMode.light;
      case ThemePreference.dark:
        return ThemeMode.dark;
      case ThemePreference.system:
      case ThemePreference.batterySaver:
        return ThemeMode.system;
    }
  }

  Future<void> completeOnboarding() async {
    onboardingCompleted = true;
    if (kIsDesktopApp) {
      desktopSetupVersionCompleted = kRequiredDesktopSetupVersion;
    }
    await prefs.setBool('onboardingCompleted', true);
    if (kIsDesktopApp) {
      await prefs.setInt('desktopSetupVersionCompleted', desktopSetupVersionCompleted);
    }
    notifyListeners();
  }

  Account? accountOf(String id) => accounts.where((a) => a.id == id).firstOrNull;
  Category? categoryOf(String id) => categories.where((c) => c.id == id).firstOrNull;
  Loan? loanOf(String id) => loans.where((l) => l.id == id).firstOrNull;
  List<LoanRepaymentReminder> loanRemindersFor(String loanId) => loanRepaymentReminders.where((r) => r.loanId == loanId).toList();
  List<LoanRepaymentReminder> get overdueLoanReminders => loanRepaymentReminders.where((r) => r.isOverdue).toList();
  List<LoanRepaymentReminder> get dueTodayLoanReminders => loanRepaymentReminders.where((r) => r.isDueToday).toList();

  List<Account> get operatingAccounts => accounts.where((a) => a.type != AccountType.savings).toList();
  List<Account> get savingAccounts => accounts.where((a) => a.type == AccountType.savings).toList();
  double get operatingAccountBalance => operatingAccounts.fold<double>(0, (sum, account) => sum + account.amount);
  double get savingAccountBalance => savingAccounts.fold<double>(0, (sum, account) => sum + account.amount);

  double get totalAccountBalance => accounts.fold<double>(0, (sum, account) => sum + account.amount);

  String format(double amount) {
    if (amountsHidden) {
      return currencyPosition == CurrencyPosition.prefix ? '$currencySymbol••••' : '••••$currencySymbol';
    }
    final formatter = NumberFormat(useSeparators ? '#,##0.##' : '0.##');
    final num = formatter.format(amount.abs());
    final sign = amount < 0 ? '-' : '';
    return currencyPosition == CurrencyPosition.prefix ? '$sign$currencySymbol$num' : '$sign$num$currencySymbol';
  }

  Future<void> toggleAmountsHidden() async {
    amountsHidden = !amountsHidden;
    await prefs.setBool('amountsHidden', amountsHidden);
    notifyListeners();
  }

  List<SavingsPurchaseSuggestion> savingsPurchaseSuggestions() => buildSavingsPurchaseSuggestions(this);

  List<SavingsPurchaseSuggestion> unseenSavingsPurchaseSuggestionsForToday() {
    final today = savingsSuggestionDayKey();
    final visibleKeys = seenSavingsSuggestionKeys.where((key) => key.startsWith('$today::')).toSet();
    return savingsPurchaseSuggestions().where((suggestion) => !visibleKeys.contains(savingsSuggestionSeenKey(suggestion.id))).toList();
  }

  Future<void> markSavingsSuggestionSeenToday(String id) async {
    final today = savingsSuggestionDayKey();
    final recentKeys = seenSavingsSuggestionKeys.where((key) {
      final parts = key.split('::');
      if (parts.length != 2) return false;
      final date = DateTime.tryParse(parts.first);
      if (date == null) return false;
      return DateTime.now().difference(date).inDays <= 14;
    }).toList();
    final key = savingsSuggestionSeenKey(id);
    if (!recentKeys.contains(key)) recentKeys.add(key);
    seenSavingsSuggestionKeys = recentKeys;
    await prefs.setStringList('seenSavingsSuggestionKeys', seenSavingsSuggestionKeys);
    notifyListeners();
  }

  Future<void> dismissFinancialHealthSummary(String key) async {
    if (!dismissedFinancialHealthSummaryKeys.contains(key)) {
      dismissedFinancialHealthSummaryKeys = [...dismissedFinancialHealthSummaryKeys, key];
      await prefs.setStringList('dismissedFinancialHealthSummaryKeys', dismissedFinancialHealthSummaryKeys);
      notifyListeners();
    }
  }

  Future<void> dismissFinancialHealthSummaries(Iterable<String> keys) async {
    final merged = {...dismissedFinancialHealthSummaryKeys, ...keys}.toList();
    dismissedFinancialHealthSummaryKeys = merged;
    await prefs.setStringList('dismissedFinancialHealthSummaryKeys', dismissedFinancialHealthSummaryKeys);
    notifyListeners();
  }

  Future<void> saveSavingsSuggestionProfile(SavingsSuggestionProfile profile) async {
    savingsSuggestionProfile = profile.copyWith(completed: true, updatedOn: DateTime.now());
    await prefs.setString('savingsSuggestionProfile', jsonEncode(savingsSuggestionProfile.toJson()));
    notifyListeners();
    queueCloudSync();
  }

  Future<void> saveSavingsIdea(String id) async {
    if (!savedSavingsIdeas.contains(id)) {
      savedSavingsIdeas = [...savedSavingsIdeas, id];
      await prefs.setStringList('savedSavingsIdeas', savedSavingsIdeas);
      notifyListeners();
      queueCloudSync();
    }
  }

  Future<void> markSavingsIdeaPlanned(String id) async {
    if (!plannedSavingsIdeas.contains(id)) {
      plannedSavingsIdeas = [...plannedSavingsIdeas, id];
      await prefs.setStringList('plannedSavingsIdeas', plannedSavingsIdeas);
      notifyListeners();
      queueCloudSync();
    }
  }

  DateRange activeRange() {
    final now = DateTime.now();
    final startToday = DateTime(now.year, now.month, now.day);
    switch (dateRangeType) {
      case DateRangeType.today:
        return DateRange(startToday, startToday.add(const Duration(days: 1)), 'Today');
      case DateRangeType.thisWeek:
        final start = startToday.subtract(Duration(days: startToday.weekday - 1));
        return DateRange(start, start.add(const Duration(days: 7)), 'This week');
      case DateRangeType.thisMonth:
        final start = DateTime(now.year, now.month, 1);
        final end = DateTime(now.year, now.month + 1, 1);
        return DateRange(start, end, DateFormat('MMMM yyyy').format(start));
      case DateRangeType.thisYear:
        return DateRange(DateTime(now.year), DateTime(now.year + 1), '${now.year}');
      case DateRangeType.allTime:
        return const DateRange(null, null, 'All time');
      case DateRangeType.custom:
        return DateRange(customStart, customEnd?.add(const Duration(days: 1)), 'Custom');
    }
  }

  List<MoneyTransaction> filteredTransactions({String? categoryId, String? accountId, List<MoneyTransactionType>? types, bool ignoreDate = false}) {
    final range = activeRange();
    return transactions.where((tx) {
      if (!ignoreDate) {
        if (range.start != null && tx.createdOn.isBefore(range.start!)) return false;
        if (range.end != null && !tx.createdOn.isBefore(range.end!)) return false;
      }
      if (filterAccountIds.isNotEmpty && !filterAccountIds.contains(tx.fromAccountId) && !(tx.toAccountId != null && filterAccountIds.contains(tx.toAccountId))) return false;
      final isReportableCategoryTransaction = tx.countsAsIncome || tx.countsAsExpense;
      if (filterCategoryIds.isNotEmpty && (!isReportableCategoryTransaction || !filterCategoryIds.contains(tx.categoryId))) return false;
      if (filterTypes.isNotEmpty && (tx.isLoanMovement || !filterTypes.contains(tx.type))) return false;
      if (categoryId != null && (!isReportableCategoryTransaction || tx.categoryId != categoryId)) return false;
      if (accountId != null && tx.fromAccountId != accountId && tx.toAccountId != accountId) return false;
      if (types != null && (tx.isLoanMovement || !types.contains(tx.type))) return false;
      return true;
    }).toList();
  }

  Summary summaryFor(List<MoneyTransaction> list) {
    double income = 0, expense = 0;
    for (final tx in list) {
      if (tx.countsAsIncome) income += tx.amount;
      if (tx.countsAsExpense) expense += tx.amount;
    }
    return Summary(income: income, expense: expense);
  }

  Map<String, double> categoryTotals(CategoryType type, {bool ignoreDate = false}) {
    final ids = categories.where((c) => c.type == type).map((c) => c.id).toSet();
    final result = <String, double>{};
    for (final tx in filteredTransactions(ignoreDate: ignoreDate)) {
      if (!ids.contains(tx.categoryId)) continue;
      if (type == CategoryType.income && !tx.countsAsIncome) continue;
      if (type == CategoryType.expense && !tx.countsAsExpense) continue;
      result[tx.categoryId] = (result[tx.categoryId] ?? 0) + tx.amount;
    }
    return result;
  }

  List<BudgetProgress> budgetProgress() {
    final result = <BudgetProgress>[];
    for (final budget in budgets) {
      final start = DateTime(budget.selectedMonth.year, budget.selectedMonth.month, 1);
      final end = DateTime(budget.selectedMonth.year, budget.selectedMonth.month + 1, 1);
      final txs = transactions.where((tx) {
        if (!tx.countsAsExpense) return false;
        if (tx.createdOn.isBefore(start) || !tx.createdOn.isBefore(end)) return false;
        if (!budget.allAccountsSelected && !budget.accountIds.contains(tx.fromAccountId)) return false;
        if (!budget.allCategoriesSelected && !budget.categoryIds.contains(tx.categoryId)) return false;
        return true;
      }).toList();
      result.add(BudgetProgress(budget, txs.fold<double>(0, (sum, tx) => sum + tx.amount), txs));
    }
    return result;
  }

  Future<void> saveTheme(ThemePreference value) async {
    themePreference = value;
    await prefs.setEnum('themePreference', value);
    notifyListeners();
    queueCloudSync();
  }

  Future<void> saveCurrency({required String symbol, required String code, required CurrencyPosition position, required bool separators}) async {
    currencySymbol = symbol;
    currencyCode = code;
    currencyPosition = position;
    useSeparators = separators;
    await prefs.setString('currencySymbol', symbol);
    await prefs.setString('currencyCode', code);
    await prefs.setEnum('currencyPosition', position);
    await prefs.setBool('useSeparators', separators);
    notifyListeners();
    queueCloudSync();
  }

  Future<void> setDateRange(DateRangeType type, {DateTime? start, DateTime? end}) async {
    dateRangeType = type;
    customStart = start;
    customEnd = end;
    await prefs.setEnum('dateRangeType', type);
    await prefs.setString('customStart', start?.toIso8601String() ?? '');
    await prefs.setString('customEnd', end?.toIso8601String() ?? '');
    notifyListeners();
    queueCloudSync();
  }

  Future<void> saveFilters({List<String>? accounts, List<String>? categories, List<MoneyTransactionType>? types}) async {
    filterAccountIds = accounts ?? filterAccountIds;
    filterCategoryIds = categories ?? filterCategoryIds;
    filterTypes = types ?? filterTypes;
    await prefs.setStringList('filterAccountIds', filterAccountIds);
    await prefs.setStringList('filterCategoryIds', filterCategoryIds);
    await prefs.setStringList('filterTypes', filterTypes.map(enumName).toList());
    notifyListeners();
    queueCloudSync();
  }

  Future<void> clearFilters() => saveFilters(accounts: [], categories: [], types: []);

  Future<void> saveDefaults({String? accountId, String? incomeCategoryId, String? expenseCategoryId}) async {
    defaultAccountId = accountId ?? defaultAccountId;
    defaultIncomeCategoryId = incomeCategoryId ?? defaultIncomeCategoryId;
    defaultExpenseCategoryId = expenseCategoryId ?? defaultExpenseCategoryId;
    await prefs.setString('defaultAccountId', defaultAccountId ?? '');
    await prefs.setString('defaultIncomeCategoryId', defaultIncomeCategoryId ?? '');
    await prefs.setString('defaultExpenseCategoryId', defaultExpenseCategoryId ?? '');
    notifyListeners();
    queueCloudSync();
  }

  Future<void> setCompactHome(bool value) async {
    compactHomeSummary = value;
    await prefs.setBool('compactHomeSummary', value);
    notifyListeners();
    queueCloudSync();
  }

  Future<void> setAppLock(bool value) async {
    appLockEnabled = value;
    await prefs.setBool('appLockEnabled', value);
    notifyListeners();
    queueCloudSync();
  }

  Future<void> setReminder(bool enabled, TimeOfDay time) async {
    reminderEnabled = enabled;
    reminderTime = time;
    await prefs.setBool('reminderEnabled', enabled);
    await prefs.setInt('reminderHour', time.hour);
    await prefs.setInt('reminderMinute', time.minute);
    if (enabled) {
      await ReminderService.scheduleDaily(time);
    } else {
      await ReminderService.cancel();
    }
    notifyListeners();
    queueCloudSync();
  }

  Future<void> saveAccount(Account account) async { await database.upsertAccount(account); await reload(queueSync: true); }
  Future<void> deleteAccount(String id) async { await database.deleteAccount(id); await reload(queueSync: true); }
  Future<void> reorderAccounts(List<Account> ordered) async { await database.reorderAccounts(ordered); await reload(queueSync: true); }
  Future<void> saveCategory(Category category) async { await database.upsertCategory(category); await reload(queueSync: true); }
  Future<void> deleteCategory(String id) async { await database.deleteCategory(id); await reload(queueSync: true); }
  Future<void> addTransaction(MoneyTransaction tx) async { await database.addTransaction(tx); await reload(queueSync: true); }
  Future<void> updateTransaction(MoneyTransaction tx) async { await database.updateTransaction(tx); await reload(queueSync: true); }
  Future<void> deleteTransaction(String id) async { await database.deleteTransaction(id); await reload(queueSync: true); }
  Future<void> saveBudget(Budget budget) async { await database.upsertBudget(budget); await reload(queueSync: true); }
  Future<void> deleteBudget(String id) async { await database.deleteBudget(id); await reload(queueSync: true); }
  Future<void> addLoan(Loan loan) async { await database.addLoan(loan); await reload(queueSync: true); }
  Future<void> updateLoan(Loan loan) async { await database.updateLoan(loan); await reload(queueSync: true); }
  Future<void> deleteLoan(String id) async {
    for (final reminder in loanRemindersFor(id)) {
      await ReminderService.cancelLoanRepaymentReminder(reminder.id);
    }
    await database.deleteLoan(id);
    await reload(queueSync: true);
  }
  Future<void> addRepayment(Loan loan, LoanRepayment repayment, String accountId) async { await database.addRepayment(loan, repayment, accountId); await reload(queueSync: true); }
  Future<void> deleteRepayment(String id) async { await database.deleteRepayment(id); await reload(queueSync: true); }

  Future<void> replaceLoanRepaymentReminders(String loanId, List<LoanRepaymentReminder> reminders) async {
    for (final oldReminder in loanRemindersFor(loanId).where((r) => !r.isPaid)) {
      await ReminderService.cancelLoanRepaymentReminder(oldReminder.id);
    }
    await database.replacePendingLoanRepaymentReminders(loanId, reminders);
    final loan = loanOf(loanId);
    if (loan != null) {
      for (final reminder in reminders) {
        await ReminderService.scheduleLoanRepaymentReminder(loan: loan, reminder: reminder);
      }
    }
    await reload(queueSync: true);
  }

  Future<void> deleteLoanRepaymentReminder(String id) async {
    await ReminderService.cancelLoanRepaymentReminder(id);
    await database.deleteLoanRepaymentReminder(id);
    await reload(queueSync: true);
  }

  Future<void> markLoanRepaymentReminderPaid(Loan loan, LoanRepaymentReminder reminder, String accountId) async {
    await database.markLoanRepaymentReminderPaid(loan, reminder, accountId);
    await ReminderService.cancelLoanRepaymentReminder(reminder.id);
    await reload(queueSync: true);
  }
}

extension FirstOrNullExtension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}


String savingsSuggestionDayKey([DateTime? date]) {
  final value = date ?? DateTime.now();
  return DateFormat('yyyy-MM-dd').format(value);
}

String savingsSuggestionSeenKey(String id, [DateTime? date]) => '${savingsSuggestionDayKey(date)}::$id';

const int kDailySavingsSuggestionLimit = 10;

List<SavingsPurchaseSuggestion> buildSavingsPurchaseSuggestions(AppController state) {
  final profile = state.savingsSuggestionProfile;
  final balance = state.savingAccountBalance;
  String range(double lowFactor, double highFactor, {double min = 300, double max = 50000}) {
    final low = balance <= 0 ? min : math.max(min, math.min(max, balance * lowFactor));
    final high = balance <= 0 ? math.max(min * 2, 1000) : math.max(low, math.min(max, balance * highFactor));
    return '${state.format(low.toDouble())} – ${state.format(high.toDouble())}';
  }

  final text = [profile.hobby, profile.occupation, profile.savingsGoal, profile.spendingPreference, profile.extraDetails]
      .join(' ')
      .toLowerCase();
  final suggestions = <SavingsPurchaseSuggestion>[];

  void add(String id, String title, String costRange, String reason, String savingsFit, String iconName, String color) {
    if (suggestions.any((s) => s.id == id)) return;
    suggestions.add(SavingsPurchaseSuggestion(id: id, title: title, costRange: costRange, reason: reason, savingsFit: savingsFit, iconName: iconName, color: color));
  }

  if (balance <= 0) {
    add('start-savings-buffer', 'Start a savings buffer', state.format(500), 'Your savings account is empty, so the safest first idea is building a small buffer before buying anything.', 'A low target helps you start without creating pressure.', 'savings', '#A6E3A1');
  }
  if (text.contains('student') || text.contains('study') || text.contains('school') || text.contains('college') || text.contains('university')) {
    add('student-study-kit', 'Study upgrade kit', range(.08, .18, min: 500, max: 8000), 'Useful for a student profile: notebooks, stationery, flash drive, or a focused study accessory.', 'Keep this below a small part of your savings so the account still grows.', 'book', '#78D8E8');
    add('course-or-exam', 'Course or exam prep', range(.12, .28, min: 800, max: 15000), 'A skill course or exam prep material can support your education instead of becoming a short-term impulse buy.', 'Best when it helps your current savings goal.', 'school', '#B4A5FF');
  }
  if (text.contains('game') || text.contains('gaming') || text.contains('gamer')) {
    add('gaming-accessory', 'Gaming accessory', range(.10, .22, min: 1000, max: 18000), 'Your profile mentions gaming, so a controller, headset, or mouse can be a relevant planned purchase.', 'Choose this only if it does not reduce your main savings goal too much.', 'sports_esports', '#FBC879');
    add('gaming-audio', 'Gaming audio upgrade', range(.08, .18, min: 900, max: 12000), 'A headset or speakers can improve long gaming sessions more than random impulse spending.', 'Keep hobby spending within a fixed limit.', 'headphones', '#B4A5FF');
  }
  if (text.contains('anime') || text.contains('manga') || text.contains('otaku')) {
    add('anime-manga-fund', 'Anime or manga fund', range(.06, .18, min: 500, max: 12000), 'A small hobby fund can help you buy manga, merch, or event tickets without touching core savings.', 'Set a fixed cap so the hobby remains controlled.', 'origami_bird', '#FF6BAA');
    add('manga-box-set', 'Manga box set or volume bundle', range(.10, .24, min: 900, max: 15000), 'If you enjoy manga, a planned volume bundle is usually better than scattered impulse purchases.', 'Choose a title you already planned to collect.', 'manga', '#F472B6');
    add('anime-collectible', 'Anime collectible or display item', range(.08, .20, min: 800, max: 14000), 'A controlled collectible budget can fit anime fans without draining your savings goal.', 'Only buy if it fits after essentials and your target savings.', 'collectibles', '#FB7185');
  }
  if (text.contains('creator') || text.contains('youtube') || text.contains('video') || text.contains('content') || text.contains('stream')) {
    add('creator-gear', 'Creator gear upgrade', range(.14, .32, min: 1500, max: 25000), 'A mic, tripod, light, or storage upgrade fits a content-creator profile and can improve output quality.', 'Prefer gear that solves a real workflow problem.', 'camera_alt', '#86E3CE');
    add('creator-audio', 'Microphone or audio accessory', range(.10, .22, min: 1200, max: 16000), 'Clearer audio can be one of the best-value upgrades for content creation.', 'Buy it only if it improves your current setup.', 'mic', '#78D8E8');
  }
  if (text.contains('read') || text.contains('book') || text.contains('novel')) {
    add('reader-stack', 'Book stack', range(.05, .14, min: 400, max: 8000), 'A planned book purchase fits your reading interest while keeping the amount modest.', 'Buy from a wishlist instead of impulse browsing.', 'book', '#FBC879');
  }
  if (text.contains('travel') || text.contains('trip')) {
    add('travel-day-plan', 'Small travel plan', range(.15, .35, min: 1500, max: 30000), 'Your profile suggests travel, so a controlled day-trip fund may fit better than random spending.', 'Keep transport, food, and emergency money inside the estimate.', 'flight', '#78D8E8');
  }
  if (text.contains('work') || text.contains('job') || text.contains('office') || text.contains('freelance')) {
    add('work-productivity', 'Work productivity item', range(.08, .22, min: 800, max: 16000), 'A practical desk, bag, keyboard, or app subscription can support your work routine.', 'Use this only if it improves daily productivity.', 'work', '#A6E3A1');
  }

  add('safe-buffer', 'Emergency buffer first', balance <= 0 ? state.format(1000) : range(.20, .45, min: 1000, max: 50000), 'Before optional purchases, keeping a reserve protects your savings from sudden needs.', 'This is the safest option if your savings goal is important.', 'health', '#A6E3A1');
  add('skill-investment', 'Skill investment', balance <= 0 ? state.format(800) : range(.08, .20, min: 800, max: 18000), 'A course, book, or tool that improves your skills can be more useful than a quick purchase.', 'Choose it when it matches your occupation or goal.', 'school', '#B4A5FF');
  add('wishlist-item', 'Planned wishlist item', balance <= 0 ? state.format(500) : range(.05, .15, min: 500, max: 12000), 'A small planned item can be reasonable if it stays within your savings limit.', 'Avoid buying it if it delays a higher-priority goal.', 'gift', '#FFB5D0');
  add('audio-upgrade', 'Headphones or earphones', balance <= 0 ? state.format(700) : range(.06, .18, min: 700, max: 10000), 'Audio gear can be a practical upgrade for study, work, or entertainment when chosen carefully.', 'Keep it in a comfortable range that does not hurt your goal.', 'headphones', '#89A7FF');
  add('digital-subscription', 'Useful subscription or membership', balance <= 0 ? state.format(300) : range(.03, .10, min: 300, max: 5000), 'A single useful subscription can be more valuable than multiple impulse purchases.', 'Only continue it if you actually use it regularly.', 'subscription', '#86E3CE');
  add('creative-hobby', 'Creative hobby supplies', balance <= 0 ? state.format(400) : range(.05, .14, min: 400, max: 8000), 'Art, journaling, or other hobby supplies can be a controlled way to enjoy your savings.', 'Set a spending ceiling before buying.', 'art', '#FBC879');
  add('small-tech-upgrade', 'Small tech or desk upgrade', balance <= 0 ? state.format(900) : range(.08, .20, min: 900, max: 18000), 'A keyboard, stand, or small device can improve daily comfort if it solves a real need.', 'Choose practical upgrades over impulse gadgets.', 'keyboard', '#78D8E8');
  add('essential-replacement', 'Essential replacement fund', balance <= 0 ? state.format(600) : range(.05, .16, min: 600, max: 12000), 'Set aside money for replacing something useful before it becomes urgent.', 'This keeps savings practical instead of only entertainment-focused.', 'tools', '#A6E3A1');
  add('health-comfort-item', 'Health or comfort item', balance <= 0 ? state.format(500) : range(.04, .14, min: 500, max: 10000), 'A planned health, comfort, or daily-use item can be reasonable when it improves routine life.', 'Keep it below your main savings target.', 'health', '#86E3CE');
  add('home-organizer', 'Home organizer or storage', balance <= 0 ? state.format(500) : range(.04, .13, min: 500, max: 9000), 'Small home organization purchases can reduce clutter without becoming a large expense.', 'Choose only one useful item and avoid extra add-ons.', 'home', '#FBC879');
  add('small-gift-plan', 'Small gift plan', balance <= 0 ? state.format(400) : range(.04, .12, min: 400, max: 8000), 'Planning a gift ahead of time prevents last-minute overspending.', 'Use a fixed cap so generosity does not break the budget.', 'gift', '#FFB5D0');
  add('do-not-buy-yet', 'Wait and compare prices', state.format(0), 'Sometimes the best suggestion is not buying now. Compare prices and wait if the item is not needed.', 'This keeps your savings intact.', 'schedule', '#9AD0F5');

  if (suggestions.length <= kDailySavingsSuggestionLimit) return suggestions;
  final now = DateTime.now();
  final daySeed = DateTime(now.year, now.month, now.day).difference(DateTime(now.year, 1, 1)).inDays;
  final start = daySeed % suggestions.length;
  return List<SavingsPurchaseSuggestion>.generate(kDailySavingsSuggestionLimit, (i) => suggestions[(start + i) % suggestions.length]);
}

// -----------------------------------------------------------------------------
// App shell and shared UI
// -----------------------------------------------------------------------------


class AppBreakpoints {
  const AppBreakpoints._();

  static const double compact = 360;
  static const double medium = 600;
  static const double expanded = 900;
  static const double large = 1180;

  static bool isSmall(BuildContext context) => MediaQuery.sizeOf(context).width < compact;
  static bool isMedium(BuildContext context) => MediaQuery.sizeOf(context).width >= medium;
  static bool isExpanded(BuildContext context) => MediaQuery.sizeOf(context).width >= expanded;
  static bool isLarge(BuildContext context) => MediaQuery.sizeOf(context).width >= large;
}

class AppMotion {
  const AppMotion._();

  static const Duration fast = Duration(milliseconds: 150);
  static const Duration medium = Duration(milliseconds: 260);
  static const Duration slow = Duration(milliseconds: 420);

  static const Curve standard = Cubic(0.2, 0.0, 0.0, 1.0);
  static const Curve emphasized = Cubic(0.05, 0.7, 0.1, 1.0);
  static const Curve emphasizedAccelerate = Cubic(0.3, 0.0, 0.8, 0.15);
  static const Curve spring = Curves.easeOutBack;
}

class AppShapes {
  const AppShapes._();

  static BorderRadius extraSmall = BorderRadius.circular(12);
  static BorderRadius small = BorderRadius.circular(16);
  static BorderRadius medium = BorderRadius.circular(20);
  static BorderRadius large = BorderRadius.circular(24);
  static BorderRadius extraLarge = BorderRadius.circular(30);
  static BorderRadius dialog = BorderRadius.circular(32);
  static BorderRadius full = BorderRadius.circular(999);

  static RoundedRectangleBorder squircle(double radius) => RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
}

class KoinlyPageTransitionsBuilder extends PageTransitionsBuilder {
  const KoinlyPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (route.isFirst) return child;
    final fade = CurvedAnimation(parent: animation, curve: AppMotion.emphasized, reverseCurve: AppMotion.emphasizedAccelerate);
    final slide = Tween<Offset>(begin: const Offset(0.035, 0), end: Offset.zero).animate(fade);
    final scale = Tween<double>(begin: .985, end: 1).animate(fade);
    return FadeTransition(
      opacity: fade,
      child: SlideTransition(
        position: slide,
        child: ScaleTransition(scale: scale, child: child),
      ),
    );
  }
}

class MotionPressable extends StatefulWidget {
  const MotionPressable({
    super.key,
    required this.child,
    this.onTap,
    this.borderRadius,
    this.scale = .975,
  });

  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius? borderRadius;
  final double scale;

  @override
  State<MotionPressable> createState() => _MotionPressableState();
}

class _MotionPressableState extends State<MotionPressable> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.borderRadius ?? AppShapes.large;
    return MouseRegion(
      cursor: widget.onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.onTap == null ? null : (_) => _setPressed(true),
        onTapCancel: widget.onTap == null ? null : () => _setPressed(false),
        onTapUp: widget.onTap == null ? null : (_) => _setPressed(false),
        onTap: widget.onTap,
        child: AnimatedScale(
          duration: AppMotion.fast,
          curve: _pressed ? Curves.easeOutCubic : AppMotion.spring,
          scale: _pressed ? widget.scale : 1,
          child: ClipRRect(borderRadius: radius, child: widget.child),
        ),
      ),
    );
  }
}

class KoinlyScrollBehavior extends MaterialScrollBehavior {
  const KoinlyScrollBehavior();

  @override
  Set<ui.PointerDeviceKind> get dragDevices => const {
        ui.PointerDeviceKind.touch,
        ui.PointerDeviceKind.mouse,
        ui.PointerDeviceKind.trackpad,
        ui.PointerDeviceKind.stylus,
        ui.PointerDeviceKind.unknown,
      };

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    if (kIsDesktopApp) return const ClampingScrollPhysics();
    return const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
  }

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) {
    if (!kIsDesktopApp) return child;
    return Scrollbar(
      controller: details.controller,
      interactive: true,
      child: child,
    );
  }
}

ScrollPhysics optimizedScrollPhysics(BuildContext context) {
  if (kIsDesktopApp) return const ClampingScrollPhysics();
  return const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
}

class KoinlyApp extends StatelessWidget {
  const KoinlyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      scrollBehavior: const KoinlyScrollBehavior(),
      title: appTitle,
      themeMode: state.themeMode,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: const StartupGate(),
      builder: (context, child) {
        final media = MediaQuery.of(context);
        final width = media.size.width;
        final maxScale = width < 360 ? 1.04 : width < 600 ? 1.14 : width < 900 ? 1.22 : 1.30;
        return MediaQuery(
          data: media.copyWith(textScaler: media.textScaler.clamp(minScaleFactor: .90, maxScaleFactor: maxScale)),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }

  ThemeData _theme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final baseScheme = ColorScheme.fromSeed(
      seedColor: kSleekAccent,
      brightness: brightness,
    );
    final scheme = isDark
        ? baseScheme.copyWith(
            primary: kSleekAccent,
            onPrimary: const Color(0xFF002022),
            secondary: const Color(0xFF2BD9A1),
            tertiary: const Color(0xFFFF5C7A),
            surface: kSleekSurface,
            surfaceContainerLow: const Color(0xFF0B1619),
            surfaceContainer: const Color(0xFF101B1F),
            surfaceContainerHigh: kSleekSurfaceHigh,
            surfaceContainerHighest: kSleekSurfaceHigher,
            background: kSleekBackground,
            outline: const Color(0xFF2A3940),
            outlineVariant: const Color(0xFF1D2A30),
          )
        : baseScheme.copyWith(
            primary: kSleekAccent,
            onPrimary: const Color(0xFF002022),
            secondary: const Color(0xFF00A879),
            tertiary: const Color(0xFFFF5074),
            surface: Colors.white,
            surfaceContainerLow: const Color(0xFFF8FDFF),
            surfaceContainer: const Color(0xFFF2F9FB),
            surfaceContainerHigh: const Color(0xFFEAF4F7),
            surfaceContainerHighest: const Color(0xFFE0EEF2),
            background: const Color(0xFFF5FAFB),
            outline: const Color(0xFFB9C9CF),
            outlineVariant: const Color(0xFFD8E6EA),
          );

    final textTheme = Typography.material2021(platform: TargetPlatform.android).black.apply(
          fontFamily: 'Roboto',
          displayColor: scheme.onSurface,
          bodyColor: scheme.onSurface,
        );

    final pageTransitionBuilder = const KoinlyPageTransitionsBuilder();

    WidgetStateProperty<T> states<T>({required T normal, T? selected, T? pressed, T? disabled}) {
      return WidgetStateProperty.resolveWith((state) {
        if (state.contains(WidgetState.disabled)) return disabled ?? normal;
        if (state.contains(WidgetState.pressed)) return pressed ?? selected ?? normal;
        if (state.contains(WidgetState.selected)) return selected ?? normal;
        return normal;
      });
    }

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.background,
      canvasColor: scheme.background,
      visualDensity: VisualDensity.standard,
      dividerColor: Colors.transparent,
      splashFactory: InkSparkle.splashFactory,
      textTheme: textTheme.copyWith(
        displaySmall: textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -1.2),
        headlineMedium: textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -.7),
        titleLarge: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -.2),
        titleMedium: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        bodyMedium: textTheme.bodyMedium?.copyWith(height: 1.35),
        bodyLarge: textTheme.bodyLarge?.copyWith(height: 1.35),
      ),
      pageTransitionsTheme: PageTransitionsTheme(
        builders: {
          TargetPlatform.android: pageTransitionBuilder,
          TargetPlatform.windows: pageTransitionBuilder,
          TargetPlatform.linux: pageTransitionBuilder,
          TargetPlatform.macOS: pageTransitionBuilder,
          TargetPlatform.iOS: pageTransitionBuilder,
        },
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surface,
        surfaceTintColor: scheme.surfaceTint,
        margin: EdgeInsets.zero,
        shape: AppShapes.squircle(26),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: scheme.surfaceTint,
        shape: RoundedRectangleBorder(borderRadius: AppShapes.dialog),
        titleTextStyle: textTheme.titleLarge?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w900),
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, height: 1.38),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: scheme.surfaceTint,
        modalBackgroundColor: scheme.surface,
        modalBarrierColor: Colors.black.withOpacity(isDark ? .62 : .36),
        showDragHandle: true,
        dragHandleColor: scheme.outlineVariant,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(kIsDesktopApp ? 34 : 30))),
        constraints: const BoxConstraints(maxWidth: 720),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        backgroundColor: isDark ? const Color(0xFF1C2B30) : const Color(0xFF0F172A),
        contentTextStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
        shape: RoundedRectangleBorder(borderRadius: AppShapes.medium),
      ),
      listTileTheme: ListTileThemeData(
        minLeadingWidth: 46,
        contentPadding: EdgeInsets.zero,
        shape: AppShapes.squircle(22),
        titleTextStyle: textTheme.titleSmall?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w900),
        subtitleTextStyle: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: Colors.transparent,
        elevation: 0,
        indicatorColor: kSleekAccent.withOpacity(isDark ? .26 : .18),
        indicatorShape: AppShapes.squircle(22),
        selectedIconTheme: const IconThemeData(color: kSleekAccent, size: 26),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant.withOpacity(.82), size: 24),
        selectedLabelTextStyle: const TextStyle(color: kSleekAccent, fontWeight: FontWeight.w900, fontSize: 12),
        unselectedLabelTextStyle: TextStyle(color: scheme.onSurfaceVariant.withOpacity(.82), fontWeight: FontWeight.w800, fontSize: 11),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? const Color(0xEE0B1417) : Colors.white.withOpacity(.96),
        indicatorColor: kSleekAccent.withOpacity(isDark ? .24 : .18),
        height: 78,
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        labelTextStyle: WidgetStateProperty.resolveWith((state) => TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: state.contains(WidgetState.selected) ? 12 : 11,
              color: state.contains(WidgetState.selected) ? kSleekAccent : scheme.onSurfaceVariant,
            )),
        iconTheme: WidgetStateProperty.resolveWith((state) => IconThemeData(
              color: state.contains(WidgetState.selected) ? kSleekAccent : scheme.onSurfaceVariant.withOpacity(.82),
              size: state.contains(WidgetState.selected) ? 26 : 23,
            )),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? scheme.surfaceContainerHigh.withOpacity(.82) : Colors.white,
        hintStyle: TextStyle(color: scheme.onSurfaceVariant.withOpacity(.78), fontWeight: FontWeight.w600),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700),
        floatingLabelStyle: const TextStyle(color: kSleekAccent, fontWeight: FontWeight.w900),
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        border: OutlineInputBorder(borderRadius: AppShapes.medium, borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: AppShapes.medium, borderSide: BorderSide(color: scheme.outlineVariant.withOpacity(.45), width: 1)),
        focusedBorder: OutlineInputBorder(borderRadius: AppShapes.large, borderSide: BorderSide(color: kSleekAccent.withOpacity(.78), width: 1.4)),
        errorBorder: OutlineInputBorder(borderRadius: AppShapes.medium, borderSide: BorderSide(color: scheme.error.withOpacity(.72), width: 1.2)),
        focusedErrorBorder: OutlineInputBorder(borderRadius: AppShapes.large, borderSide: BorderSide(color: scheme.error, width: 1.4)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: states(normal: kSleekAccent, pressed: kSleekAccent.withOpacity(.88), disabled: scheme.onSurface.withOpacity(.12)),
          foregroundColor: states(normal: const Color(0xFF021012), disabled: scheme.onSurface.withOpacity(.38)),
          overlayColor: WidgetStatePropertyAll(Colors.white.withOpacity(.10)),
          shape: WidgetStateProperty.resolveWith((state) => AppShapes.squircle(state.contains(WidgetState.pressed) ? 22 : 18)),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 22, vertical: 16)),
          minimumSize: const WidgetStatePropertyAll(Size(48, 50)),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontWeight: FontWeight.w900, letterSpacing: -.1)),
          elevation: states(normal: 0.0, pressed: 0.0),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: states(normal: kSleekAccent, pressed: kSleekAccent.withOpacity(.75)),
          shape: WidgetStateProperty.resolveWith((state) => AppShapes.squircle(state.contains(WidgetState.pressed) ? 18 : 16)),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14, vertical: 11)),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontWeight: FontWeight.w900)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: states(normal: scheme.onSurface, pressed: kSleekAccent, disabled: scheme.onSurface.withOpacity(.38)),
          side: states(
            normal: BorderSide(color: scheme.outlineVariant.withOpacity(.95), width: 1.2),
            pressed: BorderSide(color: kSleekAccent.withOpacity(.72), width: 1.3),
            disabled: BorderSide(color: scheme.onSurface.withOpacity(.12), width: 1),
          ),
          shape: WidgetStateProperty.resolveWith((state) => AppShapes.squircle(state.contains(WidgetState.pressed) ? 22 : 18)),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 20, vertical: 15)),
          minimumSize: const WidgetStatePropertyAll(Size(48, 50)),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontWeight: FontWeight.w900)),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((state) => state.contains(WidgetState.selected) ? kSleekAccent.withOpacity(isDark ? .42 : .22) : scheme.surfaceContainerHigh.withOpacity(isDark ? .58 : .72)),
          foregroundColor: WidgetStateProperty.resolveWith((state) => state.contains(WidgetState.selected) ? (isDark ? Colors.white : const Color(0xFF003033)) : scheme.onSurfaceVariant),
          side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant.withOpacity(.9), width: 1.1)),
          shape: WidgetStatePropertyAll(AppShapes.squircle(22)),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontWeight: FontWeight.w900)),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 14, horizontal: 16)),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: kSleekAccent,
        foregroundColor: const Color(0xFF021012),
        elevation: 6,
        highlightElevation: 2,
        shape: AppShapes.squircle(22),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((state) => state.contains(WidgetState.pressed) ? kSleekAccent.withOpacity(.16) : (isDark ? scheme.surfaceContainerHigh.withOpacity(.72) : Colors.white.withOpacity(.92))),
          foregroundColor: WidgetStateProperty.resolveWith((state) => state.contains(WidgetState.pressed) ? kSleekAccent : scheme.onSurface),
          shape: WidgetStateProperty.resolveWith((state) => AppShapes.squircle(state.contains(WidgetState.pressed) ? 18 : 16)),
          minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
        ),
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: scheme.background,
        surfaceTintColor: Colors.transparent,
        iconTheme: IconThemeData(color: scheme.onSurface),
        titleTextStyle: textTheme.headlineSmall?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w900, letterSpacing: -.6),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: kSleekAccent.withOpacity(isDark ? .34 : .22),
        disabledColor: scheme.onSurface.withOpacity(.08),
        side: BorderSide(color: scheme.outlineVariant.withOpacity(.92)),
        shape: AppShapes.squircle(18),
        labelStyle: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w800),
        secondaryLabelStyle: const TextStyle(color: kSleekAccent, fontWeight: FontWeight.w900),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: kSleekAccent, linearTrackColor: Color(0x3324C7D8)),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((state) => state.contains(WidgetState.selected) ? const Color(0xFF002022) : scheme.outline),
        trackColor: WidgetStateProperty.resolveWith((state) => state.contains(WidgetState.selected) ? kSleekAccent : scheme.surfaceContainerHighest),
        trackOutlineColor: WidgetStatePropertyAll(scheme.outlineVariant),
      ),
    );
  }
}

class StartupGate extends StatelessWidget {
  const StartupGate({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    if (state.loading) return const SplashScreen();
    if (!state.authenticated) return const LockScreen();
    if (!state.setupCompletedForCurrentPlatform) return const OnboardingScreen();
    return const FinancialHealthReviewGate(child: MainShell());
  }
}


class FinancialHealthReviewGate extends StatefulWidget {
  const FinancialHealthReviewGate({super.key, required this.child});

  final Widget child;

  @override
  State<FinancialHealthReviewGate> createState() => _FinancialHealthReviewGateState();
}

class _FinancialHealthReviewGateState extends State<FinancialHealthReviewGate> {
  bool _scheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final state = context.read<AppController>();
      final prompts = pendingFinancialHealthReviewPrompts(state);
      if (prompts.isEmpty) return;
      await showKoinlyPopup<void>(
        context,
        maxWidth: 680,
        maxHeight: 800,
        barrierDismissible: false,
        child: FinancialHealthReviewDialog(prompts: prompts),
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class FinancialHealthReviewPrompt {
  const FinancialHealthReviewPrompt({required this.period, required this.selectedDate});

  final FinancialHealthPeriod period;
  final DateTime selectedDate;

  String get key => financialHealthSummaryKey(period, selectedDate);
  String get label => financialPeriodLabel(period, selectedDate);
  String get title => period == FinancialHealthPeriod.monthly ? 'Monthly Summary Ready' : 'Yearly Summary Ready';
  String get subtitle => period == FinancialHealthPeriod.monthly ? '$label has ended. Review your financial health.' : '$label has ended. Review your yearly financial health.';
}

String financialHealthSummaryKey(FinancialHealthPeriod period, DateTime selectedDate) {
  return period == FinancialHealthPeriod.monthly ? "monthly:${DateFormat('yyyy-MM').format(selectedDate)}" : "yearly:${selectedDate.year}";
}

List<FinancialHealthReviewPrompt> pendingFinancialHealthReviewPrompts(AppController state, [DateTime? date]) {
  final now = date ?? DateTime.now();
  final prompts = <FinancialHealthReviewPrompt>[
    FinancialHealthReviewPrompt(period: FinancialHealthPeriod.monthly, selectedDate: DateTime(now.year, now.month - 1, 1)),
    FinancialHealthReviewPrompt(period: FinancialHealthPeriod.yearly, selectedDate: DateTime(now.year - 1, 1, 1)),
  ];

  return prompts.where((prompt) {
    if (state.dismissedFinancialHealthSummaryKeys.contains(prompt.key)) return false;
    return financialHealthSummaryHasActivity(state, prompt);
  }).toList();
}

bool financialHealthSummaryHasActivity(AppController state, FinancialHealthReviewPrompt prompt) {
  final summary = FinancialHealthSummary.build(state, period: prompt.period, selectedDate: prompt.selectedDate);
  return summary.income > 0 ||
      summary.expense > 0 ||
      summary.savingsIn > 0 ||
      summary.savingsOut > 0 ||
      summary.loansGiven > 0 ||
      summary.loansTaken > 0 ||
      summary.loanRepaymentPaid > 0 ||
      summary.loanRepaymentReceived > 0 ||
      summary.billPaymentCount > 0 ||
      summary.billUnpaidCount > 0 ||
      summary.billUpcomingCount > 0 ||
      summary.billOverdueCount > 0 ||
      summary.loanReminderCompletedCount > 0 ||
      summary.loanReminderPendingCount > 0 ||
      summary.loanReminderPartialCount > 0 ||
      summary.loanReminderOverdueCount > 0 ||
      summary.budgetItems.isNotEmpty;
}

class FinancialHealthReviewDialog extends StatefulWidget {
  const FinancialHealthReviewDialog({super.key, required this.prompts});

  final List<FinancialHealthReviewPrompt> prompts;

  @override
  State<FinancialHealthReviewDialog> createState() => _FinancialHealthReviewDialogState();
}

class _FinancialHealthReviewDialogState extends State<FinancialHealthReviewDialog> {
  late final PageController _pageController;
  int _index = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _skipAll() async {
    if (_busy) return;
    setState(() => _busy = true);
    final state = context.read<AppController>();
    await state.dismissFinancialHealthSummaries(widget.prompts.map((prompt) => prompt.key));
    if (mounted) Navigator.pop(context);
  }

  Future<void> _continue() async {
    if (_busy) return;
    setState(() => _busy = true);
    final state = context.read<AppController>();
    await state.dismissFinancialHealthSummary(widget.prompts[_index].key);
    if (!mounted) return;
    if (_index >= widget.prompts.length - 1) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _busy = false;
      _index += 1;
    });
    await _pageController.animateToPage(_index, duration: AppMotion.medium, curve: AppMotion.emphasized);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final prompt = widget.prompts[_index];
    final last = _index >= widget.prompts.length - 1;

    return SizedBox(
      height: 760,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
            child: Row(
              children: [
                iconBubble(context, prompt.period == FinancialHealthPeriod.monthly ? 'month' : 'year', prompt.period == FinancialHealthPeriod.monthly ? '#78D8E8' : '#FBC879', size: 48),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(prompt.title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900)),
                      Text(prompt.subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
                if (widget.prompts.length > 1)
                  Chip(
                    label: Text('${_index + 1}/${widget.prompts.length}'),
                    avatar: const Icon(Icons.auto_stories_rounded, size: 17),
                  ),
              ],
            ),
          ),
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: widget.prompts.length,
              itemBuilder: (context, index) {
                final item = widget.prompts[index];
                final summary = FinancialHealthSummary.build(state, period: item.period, selectedDate: item.selectedDate);
                return SingleChildScrollView(
                  physics: optimizedScrollPhysics(context),
                  padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
                  child: FinancialHealthSummarySection(summary: summary),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _skipAll,
                    icon: const Icon(Icons.skip_next_rounded),
                    label: const Text('Skip all'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _continue,
                    icon: Icon(last ? Icons.done_rounded : Icons.arrow_forward_rounded),
                    label: Text(last ? 'Done' : 'Next'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class KoinlyAppIcon extends StatelessWidget {
  const KoinlyAppIcon({super.key, this.size = 88, this.borderRadius});

  final double size;
  final double? borderRadius;

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? size * .28;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.22),
            blurRadius: size * .18,
            offset: Offset(0, size * .08),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.asset(
          'assets/icons/app_icon.png',
          fit: BoxFit.cover,
          filterQuality: FilterQuality.high,
          errorBuilder: (context, error, stackTrace) => DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              gradient: LinearGradient(colors: [Theme.of(context).colorScheme.primary, Theme.of(context).colorScheme.tertiary]),
            ),
            child: const Icon(Icons.account_balance_wallet_rounded, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const KoinlyAppIcon(size: 92, borderRadius: 30),
            const SizedBox(height: 24),
            Text(appTitle, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 16),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}

class LockScreen extends StatelessWidget {
  const LockScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppController>();
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ExpressiveCard(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_rounded, size: 64),
                  const SizedBox(height: 16),
                  Text('Unlock Koinly', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
                  const SizedBox(height: 8),
                  Text('Verify your identity to continue', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: () async {
                      state.authenticated = await state.authenticate();
                      state.notifyListeners();
                    },
                    icon: const Icon(Icons.fingerprint_rounded),
                    label: const Text('Unlock'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MainShell extends StatelessWidget {
  const MainShell({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final pages = const [
      HomeDashboardScreen(),
      AnalysisScreen(),
      LoansScreen(),
      TransactionListScreen(),
      CategoriesScreen(),
    ];

    final Widget? actionButton = state.tabIndex == 2
        ? FloatingActionButton.extended(
            heroTag: 'loanAddFab',
            onPressed: () => showLoanEditor(context, initialType: state.activeLoanType),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add loan'),
          )
        : state.tabIndex == 3
            ? FloatingActionButton.extended(
                heroTag: 'transactionAddFab',
                onPressed: () => showTransactionEditor(context),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add'),
              )
            : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final useDesktopNavigation = constraints.maxWidth >= 900;
        final extendDesktopNavigation = constraints.maxWidth >= 1180;

        void selectTab(int index) {
          state.tabIndex = index;
          state.notifyListeners();
        }

        return Scaffold(
          extendBody: !useDesktopNavigation,
          body: Row(
            children: [
              if (useDesktopNavigation)
                _SideRailNavigation(
                  selectedIndex: state.tabIndex,
                  extended: extendDesktopNavigation,
                  onSelected: selectTab,
                ),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: AnimatedSwitcher(
                        duration: AppMotion.medium,
                        switchInCurve: AppMotion.emphasized,
                        switchOutCurve: AppMotion.emphasizedAccelerate,
                        transitionBuilder: (child, animation) {
                          final curved = CurvedAnimation(parent: animation, curve: AppMotion.emphasized);
                          return FadeTransition(
                            opacity: curved,
                            child: SlideTransition(
                              position: Tween<Offset>(begin: const Offset(.018, 0), end: Offset.zero).animate(curved),
                              child: ScaleTransition(scale: Tween<double>(begin: .992, end: 1).animate(curved), child: child),
                            ),
                          );
                        },
                        child: KeyedSubtree(key: ValueKey<int>(state.tabIndex), child: pages[state.tabIndex]),
                      ),
                    ),
                    if (actionButton != null)
                      Positioned(
                        right: useDesktopNavigation ? 34 : 28,
                        bottom: MediaQuery.of(context).padding.bottom + (useDesktopNavigation ? 30 : 102),
                        child: actionButton,
                      ),
                    if (!useDesktopNavigation)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: _FloatingDockNavigation(
                          selectedIndex: state.tabIndex,
                          onSelected: selectTab,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DockDestination {
  const _DockDestination({
    required this.label,
    required this.icon,
    required this.activeIcon,
  });

  final String label;
  final IconData icon;
  final IconData activeIcon;
}

class _SideRailNavigation extends StatelessWidget {
  const _SideRailNavigation({
    required this.selectedIndex,
    required this.extended,
    required this.onSelected,
  });

  final int selectedIndex;
  final bool extended;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = dark ? Colors.white.withOpacity(.06) : scheme.outline.withOpacity(.14);
    final railColor = dark ? const Color(0xFF081316) : Colors.white;

    return Material(
      color: railColor,
      child: SafeArea(
        right: false,
        child: Container(
          width: extended ? 238 : 92,
          decoration: BoxDecoration(
            border: Border(right: BorderSide(color: borderColor, width: 1)),
            boxShadow: kIsDesktopApp
                ? null
                : [
                    BoxShadow(
                      color: Colors.black.withOpacity(dark ? .18 : .035),
                      blurRadius: 18,
                      offset: const Offset(6, 0),
                    ),
                  ],
          ),
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(extended ? 20 : 14, 18, extended ? 20 : 14, 10),
                child: Row(
                  mainAxisAlignment: extended ? MainAxisAlignment.start : MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(17),
                        gradient: LinearGradient(colors: [kSleekAccent, scheme.tertiary]),
                        boxShadow: [BoxShadow(color: kSleekAccent.withOpacity(.20), blurRadius: 18, offset: const Offset(0, 8))],
                      ),
                      child: const Icon(Icons.account_balance_wallet_rounded, color: Colors.white),
                    ),
                    if (extended) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(appTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900)),
                            Text('Desktop', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w800)),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(
                child: NavigationRail(
                  selectedIndex: selectedIndex,
                  extended: extended,
                  minWidth: 92,
                  minExtendedWidth: 238,
                  groupAlignment: -0.86,
                  backgroundColor: Colors.transparent,
                  indicatorColor: kSleekAccent.withOpacity(dark ? .26 : .16),
                  labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
                  selectedIconTheme: const IconThemeData(color: kSleekAccent, size: 26),
                  unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant.withOpacity(.82), size: 24),
                  selectedLabelTextStyle: const TextStyle(color: kSleekAccent, fontWeight: FontWeight.w900, fontSize: 12),
                  unselectedLabelTextStyle: TextStyle(color: scheme.onSurfaceVariant.withOpacity(.82), fontWeight: FontWeight.w800, fontSize: 11),
                  onDestinationSelected: onSelected,
                  destinations: _FloatingDockNavigation._destinations
                      .map(
                        (destination) => NavigationRailDestination(
                          icon: Icon(destination.icon),
                          selectedIcon: Icon(destination.activeIcon),
                          label: Text(destination.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FloatingDockNavigation extends StatelessWidget {
  const _FloatingDockNavigation({
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static const _destinations = [
    _DockDestination(label: 'Home', icon: Icons.home_outlined, activeIcon: Icons.home_rounded),
    _DockDestination(label: 'Analysis', icon: Icons.insights_outlined, activeIcon: Icons.insights_rounded),
    _DockDestination(label: 'Loans', icon: Icons.handshake_outlined, activeIcon: Icons.handshake_rounded),
    _DockDestination(label: 'Transaction', icon: Icons.receipt_long_outlined, activeIcon: Icons.receipt_long_rounded),
    _DockDestination(label: 'Categories', icon: Icons.category_outlined, activeIcon: Icons.category_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final active = kSleekAccent;
    final inactive = dark ? scheme.onSurface.withOpacity(.72) : scheme.onSurfaceVariant.withOpacity(.78);
    final dockColor = dark ? const Color(0xFF1B2024).withOpacity(.96) : Colors.white.withOpacity(.94);
    final selectedColor = dark ? kSleekAccent.withOpacity(.26) : kSleekAccent.withOpacity(.18);

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(18, 0, 18, 14),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 450),
          child: Container(
            height: 76,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: dockColor,
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: dark ? Colors.white.withOpacity(.055) : scheme.outline.withOpacity(.16), width: 1),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(dark ? .34 : .12), blurRadius: 24, offset: const Offset(0, 10)),
                BoxShadow(color: kSleekAccent.withOpacity(dark ? .08 : .05), blurRadius: 22, offset: const Offset(0, -2)),
              ],
            ),
            child: Row(
              children: List.generate(_destinations.length, (index) {
                final destination = _destinations[index];
                final selected = selectedIndex == index;
                return Expanded(
                  child: Tooltip(
                    message: destination.label,
                    child: Semantics(
                      selected: selected,
                      button: true,
                      label: destination.label,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(22),
                        onTap: () => onSelected(index),
                        child: Center(
                          child: AnimatedContainer(
                            duration: AppMotion.fast,
                            curve: AppMotion.spring,
                            width: selected ? 58 : 48,
                            height: selected ? 58 : 48,
                            decoration: BoxDecoration(
                              color: selected ? selectedColor : Colors.transparent,
                              borderRadius: BorderRadius.circular(selected ? 22 : 18),
                              border: selected ? Border.all(color: kSleekAccent.withOpacity(.18), width: 1) : null,
                              boxShadow: selected
                                  ? [BoxShadow(color: kSleekAccent.withOpacity(.14), blurRadius: 16, offset: const Offset(0, 8))]
                                  : null,
                            ),
                            child: Icon(
                              selected ? destination.activeIcon : destination.icon,
                              color: selected ? active : inactive,
                              size: selected ? 28 : 26,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}


class PageScaffold extends StatelessWidget {
  const PageScaffold({super.key, required this.title, this.actions = const [], required this.child, this.subtitle});
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = AppBreakpoints.isSmall(context);
    final desktop = AppBreakpoints.isExpanded(context);
    return Scaffold(
      backgroundColor: scheme.background,
      appBar: AppBar(
        toolbarHeight: desktop ? 84 : small ? 68 : 76,
        titleSpacing: small ? 12 : 18,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).appBarTheme.titleTextStyle?.copyWith(fontSize: desktop ? 30 : small ? 23 : 27)),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
              ),
          ],
        ),
        actions: actions
            .map((action) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: action,
                ))
            .toList(),
      ),
      body: SafeArea(top: false, child: child),
    );
  }
}

class ResponsiveContent extends StatelessWidget {
  const ResponsiveContent({
    super.key,
    required this.child,
    this.padding,
    this.mobileMaxWidth = 720,
    this.desktopMaxWidth = 1180,
  });

  final Widget child;
  final EdgeInsets? padding;
  final double mobileMaxWidth;
  final double desktopMaxWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = MediaQuery.sizeOf(context).width;
        final small = screenWidth < AppBreakpoints.compact;
        final medium = screenWidth >= AppBreakpoints.medium;
        final desktop = screenWidth >= AppBreakpoints.expanded;
        final large = screenWidth >= AppBreakpoints.large;
        final maxContentWidth = desktop ? (large ? desktopMaxWidth : math.min(desktopMaxWidth, 1040.0)) : (medium ? mobileMaxWidth : constraints.maxWidth);
        final double width = math.min(constraints.maxWidth, maxContentWidth).toDouble();
        final resolvedPadding = padding ??
            EdgeInsets.fromLTRB(
              desktop ? 32 : small ? 12 : 16,
              desktop ? 22 : small ? 6 : 8,
              desktop ? 32 : small ? 12 : 16,
              desktop ? 42 : small ? 96 : 110,
            );

        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: width,
            child: ListView(
              padding: resolvedPadding,
              physics: optimizedScrollPhysics(context),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              cacheExtent: kIsDesktopApp ? 900 : 320,
              children: [RepaintBoundary(child: child)],
            ),
          ),
        );
      },
    );
  }
}


class ResponsiveListContent extends StatelessWidget {
  const ResponsiveListContent({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.header = const [],
    this.empty,
    this.padding,
    this.mobileMaxWidth = 720,
    this.desktopMaxWidth = 1180,
    this.itemSpacing = 10,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final List<Widget> header;
  final Widget? empty;
  final EdgeInsets? padding;
  final double mobileMaxWidth;
  final double desktopMaxWidth;
  final double itemSpacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = MediaQuery.sizeOf(context).width;
        final small = screenWidth < AppBreakpoints.compact;
        final medium = screenWidth >= AppBreakpoints.medium;
        final desktop = screenWidth >= AppBreakpoints.expanded;
        final large = screenWidth >= AppBreakpoints.large;
        final maxContentWidth = desktop ? (large ? desktopMaxWidth : math.min(desktopMaxWidth, 1040.0)) : (medium ? mobileMaxWidth : constraints.maxWidth);
        final double width = math.min(constraints.maxWidth, maxContentWidth).toDouble();
        final resolvedPadding = padding ??
            EdgeInsets.fromLTRB(
              desktop ? 32 : small ? 12 : 16,
              desktop ? 22 : small ? 6 : 8,
              desktop ? 32 : small ? 12 : 16,
              desktop ? 42 : small ? 96 : 110,
            );
        final bodyCount = itemCount == 0 && empty != null ? 1 : itemCount;

        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: width,
            child: ListView.builder(
              padding: resolvedPadding,
              physics: optimizedScrollPhysics(context),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              cacheExtent: kIsDesktopApp ? 1100 : 420,
              itemCount: header.length + bodyCount,
              itemBuilder: (context, index) {
                if (index < header.length) return RepaintBoundary(child: header[index]);
                final bodyIndex = index - header.length;
                if (itemCount == 0) return RepaintBoundary(child: empty!);
                return RepaintBoundary(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: itemSpacing),
                    child: itemBuilder(context, bodyIndex),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class ExpressiveCard extends StatelessWidget {
  const ExpressiveCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.color,
    this.radius = 26,
    this.surfaceTint = true,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final double radius;
  final bool surfaceTint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = color ?? (dark ? scheme.surfaceContainer : Colors.white);
    final borderColor = dark ? Colors.white.withOpacity(.065) : scheme.outlineVariant.withOpacity(.74);
    return AnimatedContainer(
      duration: AppMotion.medium,
      curve: AppMotion.emphasized,
      decoration: BoxDecoration(
        color: baseColor,
        gradient: surfaceTint
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.alphaBlend(kSleekAccent.withOpacity(dark ? .025 : .030), baseColor),
                  baseColor,
                  Color.alphaBlend(scheme.tertiary.withOpacity(dark ? .018 : .022), baseColor),
                ],
              )
            : null,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor, width: 1),
        boxShadow: kIsDesktopApp
            ? [
                BoxShadow(color: Colors.black.withOpacity(dark ? .10 : .025), blurRadius: 18, offset: const Offset(0, 8)),
              ]
            : [
                if (dark)
                  BoxShadow(color: Colors.black.withOpacity(.20), blurRadius: 18, offset: const Offset(0, 9))
                else
                  BoxShadow(color: scheme.shadow.withOpacity(.060), blurRadius: 18, offset: const Offset(0, 9)),
              ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 22, 4, 10),
      child: Row(
        children: [
          Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -.2))),
          if (trailing != null) DefaultTextStyle.merge(style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w800), child: trailing!),
        ],
      ),
    );
  }
}


class SleekPillOption<T> {
  const SleekPillOption({required this.value, required this.label, this.icon});
  final T value;
  final String label;
  final IconData? icon;
}

class SleekPillSelector<T> extends StatelessWidget {
  const SleekPillSelector({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final List<SleekPillOption<T>> options;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (var i = 0; i < options.length; i++) ...[
          Expanded(
            child: _SleekPillButton<T>(
              option: options[i],
              selected: options[i].value == selected,
              onTap: () => onChanged(options[i].value),
            ),
          ),
          if (i != options.length - 1) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

class SleekCyclePillSelector<T> extends StatelessWidget {
  const SleekCyclePillSelector({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final List<SleekPillOption<T>> options;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final selectedIndex = options.indexWhere((option) => option.value == selected);
    final currentIndex = selectedIndex < 0 ? 0 : selectedIndex;
    final current = options[currentIndex];
    final next = options[(currentIndex + 1) % options.length];
    final selectedColor = kSleekAccent.withOpacity(.32);
    final textColor = Theme.of(context).colorScheme.onSurface;
    final mutedColor = Theme.of(context).colorScheme.onSurface.withOpacity(.60);

    return MotionPressable(
      onTap: () => onChanged(next.value),
      borderRadius: AppShapes.medium,
      child: Material(
        color: selectedColor,
        borderRadius: AppShapes.medium,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.emphasized,
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: AppShapes.medium,
            border: Border.all(color: kSleekAccent.withOpacity(.42), width: 1.1),
            boxShadow: [BoxShadow(color: kSleekAccent.withOpacity(.10), blurRadius: 16, offset: const Offset(0, 8))],
          ),
          child: Row(
            children: [
              if (current.icon != null) ...[
                Icon(current.icon, size: 22, color: kSleekAccent),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      current.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: textColor,
                            fontWeight: FontWeight.w900,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Tap to switch to ${next.label}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: mutedColor,
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(Icons.swap_horiz_rounded, color: kSleekAccent, size: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _SleekPillButton<T> extends StatelessWidget {
  const _SleekPillButton({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final SleekPillOption<T> option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final selectedColor = kSleekAccent.withOpacity(.32);
    final unselectedColor = Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(.48);
    final borderColor = selected ? kSleekAccent.withOpacity(.42) : Theme.of(context).colorScheme.outline.withOpacity(.24);
    final textColor = selected ? Colors.white : Theme.of(context).colorScheme.onSurface.withOpacity(.76);

    return MotionPressable(
      onTap: onTap,
      borderRadius: AppShapes.medium,
      child: Material(
        color: selected ? selectedColor : unselectedColor,
        borderRadius: AppShapes.medium,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.emphasized,
          constraints: const BoxConstraints(minHeight: 58),
          padding: EdgeInsets.symmetric(horizontal: AppBreakpoints.isSmall(context) ? 8 : 12, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: AppShapes.medium,
            border: Border.all(color: borderColor, width: 1),
            boxShadow: selected
                ? [BoxShadow(color: kSleekAccent.withOpacity(.10), blurRadius: 16, offset: const Offset(0, 8))]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (option.icon != null) ...[
                Icon(option.icon, size: AppBreakpoints.isSmall(context) ? 18 : 20, color: selected ? kSleekAccent : textColor),
                SizedBox(width: AppBreakpoints.isSmall(context) ? 5 : 8),
              ],
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.center,
                  child: Text(
                    option.label,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: textColor,
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


IconData iconFor(String name) {
  switch (name) {
    case 'wallet': return Icons.account_balance_wallet_rounded;
    case 'credit_card': return Icons.credit_card_rounded;
    case 'bank': return Icons.account_balance_rounded;
    case 'savings': return Icons.savings_rounded;
    case 'cash': return Icons.payments_rounded;
    case 'atm': return Icons.atm_rounded;
    case 'receipt': return Icons.receipt_long_rounded;
    case 'calculator': return Icons.calculate_rounded;
    case 'apparel': return Icons.checkroom_rounded;
    case 'shopping_bag': return Icons.shopping_bag_rounded;
    case 'cart': return Icons.shopping_cart_rounded;
    case 'store': return Icons.storefront_rounded;
    case 'food': return Icons.restaurant_rounded;
    case 'groceries': return Icons.local_grocery_store_rounded;
    case 'coffee': return Icons.local_cafe_rounded;
    case 'fastfood': return Icons.fastfood_rounded;
    case 'health': return Icons.health_and_safety_rounded;
    case 'hospital': return Icons.local_hospital_rounded;
    case 'medicine': return Icons.medication_rounded;
    case 'favorite': return Icons.favorite_rounded;
    case 'leisure': return Icons.pool_rounded;
    case 'games': return Icons.sports_esports_rounded;
    case 'movie': return Icons.movie_rounded;
    case 'music': return Icons.music_note_rounded;
    case 'sports': return Icons.sports_soccer_rounded;
    case 'fitness': return Icons.fitness_center_rounded;
    case 'book': return Icons.menu_book_rounded;
    case 'school': return Icons.school_rounded;
    case 'car': return Icons.directions_car_rounded;
    case 'bus': return Icons.directions_bus_rounded;
    case 'train': return Icons.train_rounded;
    case 'flight': return Icons.flight_rounded;
    case 'anime': return Icons.auto_awesome_rounded;
    case 'manga': return Icons.auto_stories_rounded;
    case 'collectibles': return Icons.toys_rounded;
    case 'headphones': return Icons.headphones_rounded;
    case 'keyboard': return Icons.keyboard_rounded;
    case 'laptop': return Icons.laptop_mac_rounded;
    case 'monitor': return Icons.desktop_windows_rounded;
    case 'mic': return Icons.mic_rounded;
    case 'video': return Icons.videocam_rounded;
    case 'art': return Icons.brush_rounded;
    case 'subscription': return Icons.subscriptions_rounded;
    case 'fuel': return Icons.local_gas_station_rounded;
    case 'home': return Icons.home_rounded;
    case 'house': return Icons.house_rounded;
    case 'apartment': return Icons.apartment_rounded;
    case 'utilities': return Icons.lightbulb_rounded;
    case 'water': return Icons.water_drop_rounded;
    case 'wifi': return Icons.wifi_rounded;
    case 'phone': return Icons.phone_android_rounded;
    case 'bolt': return Icons.bolt_rounded;
    case 'gift': return Icons.card_giftcard_rounded;
    case 'celebration': return Icons.celebration_rounded;
    case 'travel': return Icons.beach_access_rounded;
    case 'pets': return Icons.pets_rounded;
    case 'baby': return Icons.child_care_rounded;
    case 'beauty': return Icons.face_retouching_natural_rounded;
    case 'salary': return Icons.payments_rounded;
    case 'work': return Icons.work_rounded;
    case 'business': return Icons.business_center_rounded;
    case 'investment': return Icons.trending_up_rounded;
    case 'money': return Icons.attach_money_rounded;
    case 'exchange': return Icons.currency_exchange_rounded;
    case 'coupon': return Icons.confirmation_number_rounded;
    case 'handshake': return Icons.handshake_rounded;
    case 'donation': return Icons.volunteer_activism_rounded;
    case 'security': return Icons.security_rounded;
    case 'insurance': return Icons.policy_rounded;
    case 'tools': return Icons.build_rounded;
    case 'construction': return Icons.construction_rounded;
    case 'cleaning': return Icons.cleaning_services_rounded;
    case 'laundry': return Icons.local_laundry_service_rounded;
    case 'parking': return Icons.local_parking_rounded;
    case 'calendar': return Icons.calendar_month_rounded;
    case 'time': return Icons.schedule_rounded;
    case 'schedule': return Icons.schedule_rounded;
    case 'camera_alt': return Icons.photo_camera_rounded;
    case 'sports_esports': return Icons.sports_esports_rounded;
    case 'filter': return Icons.filter_alt_rounded;
    case 'today': return Icons.today_rounded;
    case 'week': return Icons.view_week_rounded;
    case 'month': return Icons.calendar_month_rounded;
    case 'year': return Icons.event_note_rounded;
    case 'all_time': return Icons.all_inclusive_rounded;
    case 'custom_range': return Icons.date_range_rounded;
    case 'theme_system': return Icons.devices_rounded;
    case 'theme_light': return Icons.light_mode_rounded;
    case 'theme_dark': return Icons.dark_mode_rounded;
    case 'theme_battery': return Icons.battery_saver_rounded;
    case 'flag': return Icons.flag_rounded;
    case 'profile': return Icons.account_circle_rounded;
    case 'loan_given': return Icons.call_made_rounded;
    case 'loan_taken': return Icons.call_received_rounded;
    case 'loan_received': return Icons.south_west_rounded;
    case 'loan_paid': return Icons.north_east_rounded;
    case 'warning': return Icons.warning_amber_rounded;
    case 'reminder': return Icons.notifications_active_rounded;
    default: return Icons.category_rounded;
  }
}
bool isImageIcon(String name) => name == 'origami_bird';

String imageIconAsset(String name) {
  switch (name) {
    case 'origami_bird':
      return 'assets/icons/origami_bird.png';
    default:
      return '';
  }
}

Widget iconGlyph(
  BuildContext context,
  String icon, {
  required Color color,
  required double size,
  Color? imageBackground,
}) {
  if (isImageIcon(icon)) {
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * .10),
      decoration: imageBackground == null || icon == 'origami_bird'
          ? null
          : BoxDecoration(
              color: imageBackground,
              borderRadius: BorderRadius.circular(size * .28),
            ),
      child: Image.asset(
        imageIconAsset(icon),
        width: size,
        height: size,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      ),
    );
  }
  return Icon(iconFor(icon), color: color, size: size);
}

Widget iconBubble(BuildContext context, String icon, String color, {double size = 44}) {
  final c = colorFromHex(color, fallback: Theme.of(context).colorScheme.primary);
  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: c.withOpacity(.16),
      borderRadius: BorderRadius.circular(size * .32),
      border: Border.all(color: c.withOpacity(.25), width: 1),
      boxShadow: kIsDesktopApp ? null : [BoxShadow(color: c.withOpacity(.10), blurRadius: 10, offset: const Offset(0, 4))],
    ),
    child: Center(
      child: iconGlyph(
        context,
        icon,
        color: c,
        size: size * .56,
        imageBackground: Colors.white.withOpacity(.84),
      ),
    ),
  );
}



class SelectionOption {
  const SelectionOption({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.iconName,
    required this.iconColor,
  });

  final String id;
  final String title;
  final String subtitle;
  final String iconName;
  final String iconColor;
}

SelectionOption optionFromAccount(Account account, AppController state) => SelectionOption(
      id: account.id,
      title: account.name,
      subtitle: account.type == AccountType.credit
          ? 'Credit • Available ${state.format(account.availableCredit)}'
          : account.type == AccountType.savings
              ? 'Savings account'
              : 'Regular account',
      iconName: account.iconName,
      iconColor: account.iconColor,
    );

SelectionOption optionFromCategory(Category category) => SelectionOption(
      id: category.id,
      title: category.name,
      subtitle: enumName(category.type),
      iconName: category.iconName,
      iconColor: category.iconColor,
    );

class AppleSelectionField extends StatelessWidget {
  const AppleSelectionField({
    super.key,
    required this.label,
    required this.option,
    required this.onTap,
    this.emptyText = 'Select',
  });

  final String label;
  final SelectionOption? option;
  final VoidCallback onTap;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = option;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w800,
                ),
          ),
        ),
        Material(
          color: scheme.surfaceContainerHighest.withOpacity(.52),
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(.28), width: .9),
              ),
              child: Row(
                children: [
                  if (selected != null) ...[
                    iconBubble(context, selected.iconName, selected.iconColor, size: 42),
                    const SizedBox(width: 12),
                  ] else ...[
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: kSleekAccent.withOpacity(.13),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: kSleekAccent.withOpacity(.18)),
                      ),
                      child: const Icon(Icons.touch_app_rounded, color: kSleekAccent),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          selected?.title ?? emptyText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          selected?.subtitle ?? 'Tap to choose',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.keyboard_arrow_down_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

Future<String?> showAppleWheelSelectionSheet(
  BuildContext context, {
  required String title,
  required List<SelectionOption> options,
  required String? selectedId,
}) async {
  if (options.isEmpty) return null;
  final foundIndex = options.indexWhere((option) => option.id == selectedId);
  final initialIndex = foundIndex < 0 ? 0 : foundIndex;
  var selectedIndex = initialIndex;
  final pickerController = FixedExtentScrollController(initialItem: initialIndex);

  final result = await showKoinlyPopup<String>(
    context,
    maxWidth: 520,
    maxHeight: 560,
    child: StatefulBuilder(
      builder: (dialogContext, setModalState) {
        final safeIndex = selectedIndex < 0 ? 0 : selectedIndex >= options.length ? options.length - 1 : selectedIndex;
        final selected = options[safeIndex];
        final dark = Theme.of(dialogContext).brightness == Brightness.dark;
        final innerColor = dark ? const Color(0xFF0B1417) : const Color(0xFFF5FAFB);
        final innerBorderColor = dark ? const Color(0xFF1F3036) : const Color(0xFFDCE8EB);
        final handleColor = dark ? const Color(0xFF43545B) : const Color(0xFFB7C8CE);

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(color: handleColor, borderRadius: BorderRadius.circular(999)),
              ),
              const SizedBox(height: 18),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(dialogContext).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 12),
              Container(
                height: 252,
                decoration: BoxDecoration(
                  color: innerColor,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: innerBorderColor),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    IgnorePointer(
                      child: Container(
                        height: 72,
                        margin: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: kSleekAccent.withOpacity(.10),
                          border: Border.all(color: kSleekAccent.withOpacity(.28), width: 1.1),
                        ),
                      ),
                    ),
                    ListWheelScrollView.useDelegate(
                      controller: pickerController,
                      itemExtent: 72,
                      diameterRatio: 100000,
                      perspective: 0.0001,
                      squeeze: 1.0,
                      physics: const FixedExtentScrollPhysics(),
                      overAndUnderCenterOpacity: .34,
                      onSelectedItemChanged: (index) => setModalState(() => selectedIndex = index),
                      childDelegate: ListWheelChildBuilderDelegate(
                        childCount: options.length,
                        builder: (context, index) {
                          final option = options[index];
                          final isSelected = index == safeIndex;
                          return _AppleWheelOptionRow(option: option, selected: isSelected);
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: Row(
                  key: ValueKey(selected.id),
                  children: [
                    iconBubble(dialogContext, selected.iconName, selected.iconColor, size: 40),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        selected.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(dialogContext).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900),
                      ),
                    ),
                    Text(
                      selected.subtitle,
                      style: Theme.of(dialogContext).textTheme.labelMedium?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, options[safeIndex].id),
                      child: const Text('Done'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    ),
  );

  pickerController.dispose();
  return result;
}

class _AppleWheelOptionRow extends StatelessWidget {
  const _AppleWheelOptionRow({required this.option, required this.selected});

  final SelectionOption option;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w900,
          color: selected ? Theme.of(context).colorScheme.onSurface : Theme.of(context).colorScheme.onSurface.withOpacity(.72),
        );
    final subtitleStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: selected ? kSleekMuted : kSleekMuted.withOpacity(.72),
          fontWeight: FontWeight.w700,
        );

    return Align(
      alignment: Alignment.center,
      child: SizedBox(
        height: 72,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              iconBubble(context, option.iconName, option.iconColor, size: selected ? 46 : 40),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(option.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle),
                    const SizedBox(height: 3),
                    Text(option.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: subtitleStyle),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


Future<DateTime?> pickDate(BuildContext context, DateTime initial) => showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );

Future<TimeOfDay?> pickTime(BuildContext context, TimeOfDay initial) => showTimePicker(context: context, initialTime: initial);

OverlayEntry? _activeKoinlySnackEntry;

void showSnack(BuildContext context, String message) {
  final trimmedMessage = message.trim();
  if (trimmedMessage.isEmpty) return;

  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(trimmedMessage)));
    return;
  }

  _activeKoinlySnackEntry?.remove();
  _activeKoinlySnackEntry = null;

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (overlayContext) => _KoinlyDynamicIslandSnack(
      message: trimmedMessage,
      onDismissed: () {
        if (_activeKoinlySnackEntry == entry) {
          _activeKoinlySnackEntry = null;
          entry.remove();
        }
      },
    ),
  );

  _activeKoinlySnackEntry = entry;
  overlay.insert(entry);
}

class _KoinlyDynamicIslandSnack extends StatefulWidget {
  const _KoinlyDynamicIslandSnack({required this.message, required this.onDismissed});

  final String message;
  final VoidCallback onDismissed;

  @override
  State<_KoinlyDynamicIslandSnack> createState() => _KoinlyDynamicIslandSnackState();
}

class _KoinlyDynamicIslandSnackState extends State<_KoinlyDynamicIslandSnack> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _hideTimer;

  bool get _isProblemMessage {
    final lower = widget.message.toLowerCase();
    return lower.contains('failed') ||
        lower.contains('error') ||
        lower.contains('invalid') ||
        lower.contains('check') ||
        lower.contains('missing');
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 620),
      reverseDuration: const Duration(milliseconds: 260),
    );
    _controller.forward();
    _hideTimer = Timer(const Duration(milliseconds: 3400), () async {
      if (!mounted) return;
      await _controller.reverse();
      if (mounted) widget.onDismissed();
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final maxWidth = math.min(kIsDesktopApp ? 520.0 : 560.0, math.max(280.0, media.size.width - 28));
    final expandedHeight = widget.message.length > 96 ? 108.0 : widget.message.length > 54 ? 86.0 : 64.0;
    final topInset = media.padding.top + (kIsDesktopApp ? 14.0 : 8.0);

    return IgnorePointer(
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final raw = _controller.value;
                final t = AppMotion.emphasized.transform(raw);
                final contentT = (((t - .34) / .66).clamp(0.0, 1.0)).toDouble();
                final width = ui.lerpDouble(92, maxWidth, t)!;
                final height = ui.lerpDouble(38, expandedHeight, t)!;
                final radius = ui.lerpDouble(999, 28, t)!;
                final y = ui.lerpDouble(-52, 0, t)!;
                final compactScale = ui.lerpDouble(.72, 1, t)!;
                final borderOpacity = ui.lerpDouble(.16, .09, t)!;
                final icon = _isProblemMessage ? Icons.error_rounded : Icons.check_circle_rounded;
                final iconColor = _isProblemMessage ? kSleekWarning : kSleekAccent;

                return Positioned(
                  top: topInset + y,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Transform.scale(
                      scale: compactScale,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(radius),
                        child: BackdropFilter(
                          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 80),
                            curve: Curves.linear,
                            width: width,
                            height: height,
                            decoration: BoxDecoration(
                              color: dark ? const Color(0xF20A1518) : const Color(0xF20F172A),
                              borderRadius: BorderRadius.circular(radius),
                              border: Border.all(color: Colors.white.withOpacity(borderOpacity)),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(dark ? .42 : .24),
                                  blurRadius: 34,
                                  offset: const Offset(0, 16),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(radius),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Align(
                                    alignment: Alignment.center,
                                    child: Container(
                                      width: ui.lerpDouble(34, 0, contentT)!,
                                      height: ui.lerpDouble(6, 0, contentT)!,
                                      decoration: BoxDecoration(
                                        color: Colors.white.withOpacity(ui.lerpDouble(.72, 0, contentT)!),
                                        borderRadius: AppShapes.full,
                                      ),
                                    ),
                                  ),
                                  Opacity(
                                    opacity: contentT,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 14),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 38,
                                            height: 38,
                                            decoration: BoxDecoration(
                                              color: iconColor.withOpacity(.18),
                                              borderRadius: BorderRadius.circular(18),
                                              border: Border.all(color: iconColor.withOpacity(.22)),
                                            ),
                                            child: Icon(icon, color: iconColor, size: 21),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              widget.message,
                                              maxLines: 3,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.bodyMedium?.copyWith(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w900,
                                                height: 1.14,
                                                letterSpacing: -.1,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}


Future<T?> showKoinlyPopup<T>(
  BuildContext context, {
  required Widget child,
  double maxWidth = 560,
  double maxHeight = 760,
  bool barrierDismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withOpacity(.62),
    transitionDuration: AppMotion.medium,
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      return _KoinlyPopupFrame(maxWidth: maxWidth, maxHeight: maxHeight, child: child);
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(parent: animation, curve: AppMotion.emphasized, reverseCurve: AppMotion.emphasizedAccelerate);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: .94, end: 1).animate(curved),
          child: SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, .035), end: Offset.zero).animate(curved),
            child: child,
          ),
        ),
      );
    },
  );
}

class _KoinlyPopupFrame extends StatelessWidget {
  const _KoinlyPopupFrame({required this.child, required this.maxWidth, required this.maxHeight});

  final Widget child;
  final double maxWidth;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final horizontalInset = media.size.width < 420 ? 12.0 : 20.0;
    final verticalInset = media.size.height < 720 ? 10.0 : 20.0;
    final availableWidth = math.max(280.0, media.size.width - (horizontalInset * 2));
    final availableHeight = math.max(
      300.0,
      media.size.height - media.padding.top - media.padding.bottom - media.viewInsets.bottom - (verticalInset * 2),
    );
    final resolvedWidth = math.min(maxWidth, availableWidth);
    final resolvedHeight = math.min(maxHeight, availableHeight);

    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        child: AnimatedPadding(
          duration: AppMotion.fast,
          curve: AppMotion.emphasized,
          padding: EdgeInsets.fromLTRB(horizontalInset, verticalInset, horizontalInset, verticalInset + media.viewInsets.bottom),
          child: Align(
            alignment: Alignment.center,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: resolvedWidth, maxHeight: resolvedHeight),
              child: Material(
                color: dark ? kSleekSurface : scheme.surface,
                elevation: 18,
                shadowColor: Colors.black.withOpacity(.45),
                borderRadius: BorderRadius.circular(media.size.width < 420 ? 30 : 34),
                clipBehavior: Clip.antiAlias,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(media.size.width < 420 ? 30 : 34),
                    border: Border.all(color: dark ? Colors.white.withOpacity(.08) : scheme.outline.withOpacity(.16)),
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Onboarding
// -----------------------------------------------------------------------------

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final controller = PageController();
  int index = 0;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final desktop = constraints.maxWidth >= 900;
            final horizontalPadding = desktop ? 32.0 : 20.0;
            return Column(
              children: [
                Expanded(
                  child: PageView(
                    controller: controller,
                    physics: const PageScrollPhysics(parent: ClampingScrollPhysics()),
                    onPageChanged: (value) => setState(() => index = value),
                    children: [
                      _OnboardingPane(
                        icon: Icons.account_balance_wallet_rounded,
                        title: 'Track money without losing detail',
                        body: 'Accounts, categories, transactions, budgets, loans, analysis, exports, reminders, local backup, and optional online sync are available from the first setup.',
                      ),
                      CurrencySetupPane(state: state),
                      AccountSetupPane(state: state),
                      _OnboardingPane(
                        icon: Icons.privacy_tip_rounded,
                        title: 'Private local database',
                        body: 'Your main finance data is stored locally with SQLite by default. Online sync uploads data only after you configure a Sync ID and PIN in Settings.',
                      ),
                    ],
                  ),
                ),
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.fromLTRB(horizontalPadding, 16, horizontalPadding, 20),
                  decoration: BoxDecoration(
                    color: Theme.of(context).scaffoldBackgroundColor.withOpacity(.94),
                    border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant.withOpacity(.55))),
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 780),
                      child: Row(
                        children: [
                          Row(
                            children: List.generate(4, (i) => AnimatedContainer(
                                  duration: AppMotion.medium,
                                  width: i == index ? 24 : 8,
                                  height: 8,
                                  margin: const EdgeInsets.only(right: 6),
                                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(99), color: i == index ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outlineVariant),
                                )),
                          ),
                          const Spacer(),
                          if (index > 0)
                            Padding(
                              padding: const EdgeInsets.only(right: 10),
                              child: OutlinedButton(
                                onPressed: () => controller.previousPage(duration: AppMotion.medium, curve: Curves.easeOutCubic),
                                child: const Text('Back'),
                              ),
                            ),
                          FilledButton(
                            onPressed: () async {
                              if (index < 3) {
                                await controller.nextPage(duration: AppMotion.medium, curve: Curves.easeOutCubic);
                              } else {
                                await state.completeOnboarding();
                              }
                            },
                            child: Text(index < 3 ? 'Next' : 'Start'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class OnboardingPageFrame extends StatelessWidget {
  const OnboardingPageFrame({super.key, required this.child, this.maxWidth = 760});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= 900;
        final horizontalPadding = desktop ? 40.0 : 24.0;
        final verticalPadding = desktop ? 32.0 : 24.0;
        return SingleChildScrollView(
          physics: optimizedScrollPhysics(context),
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding, vertical: verticalPadding),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: math.max(0, constraints.maxHeight - verticalPadding * 2)),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _OnboardingPane extends StatelessWidget {
  const _OnboardingPane({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return OnboardingPageFrame(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const KoinlyAppIcon(size: 112, borderRadius: 36),
          const SizedBox(height: 28),
          Icon(icon, size: 34, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900)),
          const SizedBox(height: 16),
          Text(body, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
        ],
      ),
    );
  }
}

class CurrencySetupPane extends StatelessWidget {
  const CurrencySetupPane({super.key, required this.state});
  final AppController state;

  @override
  Widget build(BuildContext context) {
    return OnboardingPageFrame(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const KoinlyAppIcon(size: 82, borderRadius: 26),
          const SizedBox(height: 24),
          Text('Currency setup', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900)),
          const SizedBox(height: 12),
          const Text('Choose how every amount is formatted across accounts, loans, budgets, analysis, and exports.', textAlign: TextAlign.center),
          const SizedBox(height: 24),
          CurrencyForm(initialSymbol: state.currencySymbol, initialCode: state.currencyCode, initialPosition: state.currencyPosition, initialSeparators: state.useSeparators),
        ],
      ),
    );
  }
}

class AccountSetupPane extends StatelessWidget {
  const AccountSetupPane({super.key, required this.state});
  final AppController state;

  @override
  Widget build(BuildContext context) {
    return OnboardingPageFrame(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const KoinlyAppIcon(size: 82, borderRadius: 26),
          const SizedBox(height: 24),
          Text('Accounts are ready', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900)),
          const SizedBox(height: 12),
          const Text('The app preloads Cash, Card, and Bank Account. You can create, edit, delete, reorder, and configure credit limits later.', textAlign: TextAlign.center),
          const SizedBox(height: 24),
          ...state.accounts.map((a) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: AccountTile(account: a, onTap: () => showAccountEditor(context, account: a)),
              )),
          OutlinedButton.icon(onPressed: () => showAccountEditor(context, allowedTypes: const [AccountType.regular, AccountType.credit]), icon: const Icon(Icons.add_rounded), label: const Text('Create account')),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Home Dashboard
// -----------------------------------------------------------------------------

class HomeDashboardScreen extends StatelessWidget {
  const HomeDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final range = state.activeRange();
    final txs = state.filteredTransactions();
    final summary = state.summaryFor(txs);
    final accountBalance = state.totalAccountBalance;
    final categoryTotals = state.categoryTotals(CategoryType.expense);
    final topCategories = categoryTotals.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    final balanceCard = BalanceHeroCard(
      balance: state.format(accountBalance),
      income: state.format(summary.income),
      expense: state.format(summary.expense),
      subtitle: '${state.accounts.length} accounts total • ${state.activeRange().label} balance ${state.format(summary.balance)}',
      amountsHidden: state.amountsHidden,
      onToggleAmounts: state.toggleAmountsHidden,
    );

    final accountsSection = <Widget>[
      const SectionHeader('Accounts'),
      HomeNavigationTile(
        iconName: 'wallet',
        iconColor: '#78D8E8',
        title: 'Accounts',
        subtitle: '${state.operatingAccounts.length} regular accounts',
        amount: state.format(state.operatingAccountBalance),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AccountListScreen())),
      ),
      const SizedBox(height: 10),
      HomeNavigationTile(
        iconName: 'savings',
        iconColor: '#A6E3A1',
        title: 'Savings Accounts',
        subtitle: state.savingAccounts.length == 1 ? '1 savings account' : '${state.savingAccounts.length} savings accounts',
        amount: state.format(state.savingAccountBalance),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AccountListScreen(filterType: AccountType.savings, title: 'Savings Accounts'))),
      ),
    ];

    final budgetSection = <Widget>[
      SectionHeader('Budgets', trailing: TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BudgetListScreen())), child: const Text('View all'))),
      if (state.budgets.isEmpty)
        EmptyCard(icon: Icons.savings_rounded, title: 'No budget yet', body: 'Create a monthly budget and track spending against limits.', action: () => showBudgetEditor(context), actionLabel: 'Create budget')
      else
        ...state.budgetProgress().take(2).map((b) => Padding(padding: const EdgeInsets.only(bottom: 10), child: BudgetProgressTile(progress: b))),
    ];


    final overdueLoanSection = <Widget>[
      if (state.overdueLoanReminders.isNotEmpty) ...[
        const SectionHeader('Loan alerts'),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            final reminder = state.overdueLoanReminders.firstOrNull;
            final loan = reminder == null ? null : state.loanOf(reminder.loanId);
            if (loan != null) {
              state.activeLoanType = loan.type;
            }
            state.tabIndex = 2;
            state.notifyListeners();
          },
          child: ExpressiveCard(
            color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF2A1719) : const Color(0xFFFFF0F0),
            child: Row(
              children: [
                iconBubble(context, 'warning', '#FF5353', size: 50),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${state.overdueLoanReminders.length} overdue loan repayment${state.overdueLoanReminders.length == 1 ? '' : 's'}', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
                      const SizedBox(height: 4),
                      Text('Open Loan Tracking to mark repayments as paid.', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        ),
      ],
    ];

    final categorySection = <Widget>[
      SectionHeader('Category spending'),
      if (topCategories.isEmpty)
        const EmptyCard(icon: Icons.pie_chart_rounded, title: 'No spending data', body: 'Add expenses to see where money is going.')
      else
        ExpressiveCard(
          child: Column(
            children: topCategories.take(4).map((entry) {
              final category = state.categoryOf(entry.key);
              final total = categoryTotals.values.fold<double>(0, (s, v) => s + v);
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: category == null ? null : iconBubble(context, category.iconName, category.iconColor),
                title: Text(category?.name ?? 'Unknown'),
                subtitle: LinearProgressIndicator(value: total <= 0 ? 0 : entry.value / total),
                trailing: Text(state.format(entry.value), style: const TextStyle(fontWeight: FontWeight.w800)),
                onTap: category == null ? null : () => Navigator.push(context, MaterialPageRoute(builder: (_) => CategoryTransactionScreen(category: category))),
              );
            }).toList(),
          ),
        ),
    ];


    return PageScaffold(
      title: 'Home',
      subtitle: range.label,
      actions: [
        IconButton(onPressed: () => showDateRangeSheet(context), icon: const Icon(Icons.date_range_rounded)),
        IconButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())), icon: const Icon(Icons.settings_rounded)),
      ],
      child: ResponsiveContent(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final useDesktopColumns = constraints.maxWidth >= 860;
            if (!useDesktopColumns) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  balanceCard,
                  ...overdueLoanSection,
                  ...accountsSection,
                  ...budgetSection,
                  ...categorySection,
                ],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 5,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      balanceCard,
                      ...overdueLoanSection,
                      ...accountsSection,
                      ...budgetSection,
                    ],
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  flex: 4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ...categorySection,
                        ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}


class HomeNavigationTile extends StatelessWidget {
  const HomeNavigationTile({
    super.key,
    required this.iconName,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.onTap,
  });

  final String iconName;
  final String iconColor;
  final String title;
  final String subtitle;
  final String amount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ExpressiveCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: iconBubble(context, iconName, iconColor, size: 50),
        title: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
        subtitle: Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(amount, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

class MiniMetric extends StatelessWidget {
  const MiniMetric(this.label, this.value, this.icon, {super.key});
  final String label;
  final String value;
  final IconData icon;

  Color _accent() {
    final lower = label.toLowerCase();
    if (lower.contains('income') || lower.contains('saving')) return kSleekIncome;
    if (lower.contains('expense') || lower.contains('spent') || lower.contains('overdue')) return kSleekExpense;
    if (lower.contains('balance') || lower.contains('remaining')) return kSleekAccent;
    if (lower.contains('principal') || lower.contains('open')) return const Color(0xFF8AB4FF);
    if (lower.contains('repaid') || lower.contains('completed')) return const Color(0xFF2BD9A1);
    return kSleekAccent;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final accent = _accent();

    Widget fitted(String text, TextStyle? style, {Alignment alignment = Alignment.centerLeft, TextAlign textAlign = TextAlign.left}) => FittedBox(
          fit: BoxFit.scaleDown,
          alignment: alignment,
          child: Text(
            text,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
            textAlign: textAlign,
            style: style,
          ),
        );

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 230;
        return Container(
          constraints: BoxConstraints(minHeight: compact ? 86 : 68),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest.withOpacity(.48),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: colorScheme.outline.withOpacity(.28), width: .8),
          ),
          child: compact
              ? Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(color: accent.withOpacity(.14), borderRadius: BorderRadius.circular(12)),
                      child: Icon(icon, color: accent, size: 21),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(width: double.infinity, child: fitted(label, textTheme.labelMedium?.copyWith(color: colorScheme.onSurfaceVariant, fontWeight: FontWeight.w800))),
                          const SizedBox(height: 5),
                          SizedBox(width: double.infinity, child: fitted(value, textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900, color: colorScheme.onSurface))),
                        ],
                      ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(color: accent.withOpacity(.14), borderRadius: BorderRadius.circular(12)),
                      child: Icon(icon, color: accent, size: 21),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: fitted(label, textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant, fontWeight: FontWeight.w700))),
                    const SizedBox(width: 12),
                    Flexible(child: fitted(value, textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900), alignment: Alignment.centerRight, textAlign: TextAlign.right)),
                  ],
                ),
        );
      },
    );
  }
}

class BalanceHeroCard extends StatelessWidget {
  const BalanceHeroCard({
    super.key,
    required this.balance,
    required this.income,
    required this.expense,
    required this.subtitle,
    required this.amountsHidden,
    required this.onToggleAmounts,
  });
  final String balance;
  final String income;
  final String expense;
  final String subtitle;
  final bool amountsHidden;
  final VoidCallback onToggleAmounts;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = dark ? const Color(0xFFC8E7EC) : scheme.onSurface.withOpacity(.86);
    final valueColor = dark ? Colors.white : scheme.onSurface;
    final subtitleColor = dark ? const Color(0xFF9AB0B8) : scheme.onSurfaceVariant.withOpacity(.78);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: dark
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFF0A3137),
                  const Color(0xFF0D2025),
                  scheme.surface,
                ],
              )
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white,
                  const Color(0xFFF2FBFC),
                  scheme.surface,
                ],
              ),
        border: Border.all(color: dark ? kSleekAccent.withOpacity(.18) : scheme.outline.withOpacity(.16), width: 1),
        boxShadow: kIsDesktopApp
            ? null
            : [
                BoxShadow(color: kSleekAccent.withOpacity(dark ? .08 : .05), blurRadius: 18, offset: const Offset(0, 9)),
                BoxShadow(color: Colors.black.withOpacity(dark ? .22 : .055), blurRadius: 16, offset: const Offset(0, 8)),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Net Balance', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: titleColor, fontWeight: FontWeight.w800)),
              const SizedBox(width: 6),
              Tooltip(
                message: amountsHidden ? 'Show amounts' : 'Hide amounts',
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: onToggleAmounts,
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Icon(
                      amountsHidden ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                      size: 16,
                      color: dark ? const Color(0xFF9EDDE7) : kSleekAccent.withOpacity(.82),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(balance, maxLines: 1, softWrap: false, style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -1.2, color: valueColor)),
            ),
          ),
          const SizedBox(height: 7),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: subtitleColor, fontWeight: FontWeight.w700)),
          const SizedBox(height: 18),
          const _DecorativeSparkline(),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(child: MiniMetric('Total income', income, Icons.south_west_rounded)),
              const SizedBox(width: 10),
              Expanded(child: MiniMetric('Total expense', expense, Icons.north_east_rounded)),
            ],
          ),
        ],
      ),
    );
  }
}

class _DecorativeSparkline extends StatelessWidget {
  const _DecorativeSparkline();

  @override
  Widget build(BuildContext context) {
    final spots = const [
      FlSpot(0, 1.2),
      FlSpot(1, 1.7),
      FlSpot(2, 1.4),
      FlSpot(3, 2.4),
      FlSpot(4, 2.1),
      FlSpot(5, 3.2),
      FlSpot(6, 2.9),
      FlSpot(7, 4.0),
    ];
    return RepaintBoundary(
      child: SizedBox(
        height: 54,
        child: LineChart(
        LineChartData(
          minX: 0,
          maxX: 7,
          minY: 0,
          maxY: 4.5,
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          titlesData: const FlTitlesData(show: false),
          lineTouchData: const LineTouchData(enabled: false),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              preventCurveOverShooting: true,
              color: kSleekAccent,
              barWidth: 3,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [kSleekAccent.withOpacity(.25), kSleekAccent.withOpacity(0)],
                ),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

class EmptyCard extends StatelessWidget {
  const EmptyCard({super.key, required this.icon, required this.title, required this.body, this.action, this.actionLabel});
  final IconData icon;
  final String title;
  final String body;
  final VoidCallback? action;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    return ExpressiveCard(
      child: Column(
        children: [
          Icon(icon, size: 42),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          Text(body, textAlign: TextAlign.center),
          if (action != null) ...[
            const SizedBox(height: 12),
            FilledButton(onPressed: action, child: Text(actionLabel ?? 'Add')),
          ],
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Accounts and categories management
// -----------------------------------------------------------------------------

class AccountTile extends StatelessWidget {
  const AccountTile({super.key, required this.account, this.onTap});
  final Account account;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    return ExpressiveCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: iconBubble(context, account.iconName, account.iconColor, size: 46),
        title: Text(account.name, style: const TextStyle(fontWeight: FontWeight.w900)),
        subtitle: Text(
          account.type == AccountType.credit
              ? 'Credit • Available ${state.format(account.availableCredit)}'
              : account.type == AccountType.savings
                  ? 'Savings Account'
                  : 'Cash Wallet',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(state.format(account.amount), style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}


class AccountListScreen extends StatelessWidget {
  const AccountListScreen({super.key, this.filterType, this.title = 'Accounts'});

  final AccountType? filterType;
  final String title;

  bool _matches(Account account) {
    if (filterType == AccountType.savings) return account.type == AccountType.savings;
    return account.type != AccountType.savings;
  }

  AccountType get _initialType => filterType == AccountType.savings ? AccountType.savings : AccountType.regular;
  List<AccountType> get _allowedTypes => filterType == AccountType.savings
      ? const [AccountType.savings]
      : const [AccountType.regular, AccountType.credit];

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final visibleAccounts = state.accounts.where(_matches).toList();
    final emptyTitle = filterType == AccountType.savings ? 'No savings accounts' : 'No accounts';
    final emptyBody = filterType == AccountType.savings
        ? 'Create a savings account. Balance changes here do not create income, expense, or transaction history.'
        : 'Create your first account to start tracking money.';
    final empty = EmptyCard(
      icon: filterType == AccountType.savings ? Icons.savings_rounded : Icons.account_balance_wallet_rounded,
      title: emptyTitle,
      body: emptyBody,
      action: () => showAccountEditor(context, initialType: _initialType, allowedTypes: _allowedTypes),
      actionLabel: filterType == AccountType.savings ? 'Add savings account' : 'Add account',
    );

    return PageScaffold(
      title: title,
      actions: [
        IconButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AccountReorderScreen(filterType: filterType))), icon: const Icon(Icons.swap_vert_rounded)),
        IconButton(onPressed: () => showAccountEditor(context, initialType: _initialType, allowedTypes: _allowedTypes), icon: const Icon(Icons.add_rounded)),
      ],
      child: filterType == AccountType.savings
          ? SavingsAccountsContent(accounts: visibleAccounts, empty: empty, allowedTypes: _allowedTypes)
          : ResponsiveListContent(
              itemCount: visibleAccounts.length,
              empty: empty,
              itemBuilder: (context, index) {
                final account = visibleAccounts[index];
                return AccountTile(account: account, onTap: () => showAccountEditor(context, account: account, allowedTypes: _allowedTypes));
              },
            ),
    );
  }
}


class SavingsAccountsContent extends StatefulWidget {
  const SavingsAccountsContent({super.key, required this.accounts, required this.empty, required this.allowedTypes});

  final List<Account> accounts;
  final Widget empty;
  final List<AccountType> allowedTypes;

  @override
  State<SavingsAccountsContent> createState() => _SavingsAccountsContentState();
}

class _SavingsAccountsContentState extends State<SavingsAccountsContent> {
  bool _profilePromptScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = context.read<AppController>();
    if (!_profilePromptScheduled && !state.savingsSuggestionProfile.completed) {
      _profilePromptScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await showSavingsSuggestionProfileSheet(context, firstRun: true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ResponsiveContent(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.accounts.isEmpty)
                widget.empty
              else
                ...widget.accounts.map(
                  (account) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: AccountTile(account: account, onTap: () => showAccountEditor(context, account: account, allowedTypes: widget.allowedTypes)),
                  ),
                ),
              if (widget.accounts.isNotEmpty) const SizedBox(height: 420),
            ],
          ),
        ),
        if (widget.accounts.isNotEmpty) const Positioned.fill(child: SavingsSuggestionPanel()),
      ],
    );
  }
}

class SavingsSuggestionPanel extends StatefulWidget {
  const SavingsSuggestionPanel({super.key});

  @override
  State<SavingsSuggestionPanel> createState() => _SavingsSuggestionPanelState();
}

class _SavingsSuggestionPanelState extends State<SavingsSuggestionPanel> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final math.Random _random = math.Random();
  Timer? _cycleTimer;
  String? _poppedId;
  SavingsPurchaseSuggestion? _visibleSuggestion;
  bool _bubbleVisible = false;
  double _horizontalFactor = .5;
  double _verticalFactor = .5;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))..repeat(reverse: true);
    _scheduleNextAppearance(initial: true);
  }

  @override
  void dispose() {
    _cycleTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _scheduleNextAppearance({bool initial = false}) {
    _cycleTimer?.cancel();
    final delay = initial ? const Duration(milliseconds: 550) : Duration(milliseconds: 900 + _random.nextInt(1700));
    _cycleTimer = Timer(delay, _showRandomBubble);
  }

  void _showRandomBubble() {
    if (!mounted) return;
    final suggestions = context.read<AppController>().unseenSavingsPurchaseSuggestionsForToday();
    if (suggestions.isEmpty) {
      setState(() {
        _bubbleVisible = false;
        _visibleSuggestion = null;
      });
      return;
    }

    final suggestion = suggestions[_random.nextInt(suggestions.length)];
    setState(() {
      _visibleSuggestion = suggestion;
      _bubbleVisible = true;
      _horizontalFactor = _random.nextDouble();
      _verticalFactor = _random.nextDouble();
    });

    _cycleTimer = Timer(Duration(milliseconds: 3200 + _random.nextInt(1900)), () {
      if (!mounted) return;
      setState(() => _bubbleVisible = false);
      _scheduleNextAppearance();
    });
  }

  Future<void> _popBubble(SavingsPurchaseSuggestion suggestion) async {
    _cycleTimer?.cancel();
    setState(() => _poppedId = suggestion.id);
    unawaited(HapticFeedback.mediumImpact());
    unawaited(SystemSound.play(SystemSoundType.click));
    await Future<void>.delayed(const Duration(milliseconds: 135));
    if (!mounted) return;
    await showKoinlyPopup<void>(
      context,
      maxWidth: 520,
      maxHeight: 620,
      child: SavingsSuggestionDetailDialog(suggestion: suggestion),
    );
    if (!mounted) return;
    await context.read<AppController>().markSavingsSuggestionSeenToday(suggestion.id);
    if (!mounted) return;
    setState(() {
      _poppedId = null;
      _bubbleVisible = false;
      _visibleSuggestion = null;
    });
    if (context.read<AppController>().unseenSavingsPurchaseSuggestionsForToday().isNotEmpty) {
      _scheduleNextAppearance();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final unseenSuggestions = state.unseenSavingsPurchaseSuggestionsForToday();
    if (unseenSuggestions.isEmpty) return const SizedBox.shrink();

    final visibleSuggestion = _visibleSuggestion;
    if (visibleSuggestion == null || !unseenSuggestions.any((suggestion) => suggestion.id == visibleSuggestion.id)) {
      return const SizedBox.shrink();
    }

    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final height = constraints.maxHeight;
          final bubbleSize = width < 390 ? 66.0 : 74.0;
          final leftSafe = width < 390 ? 18.0 : 28.0;
          final rightSafe = width < 390 ? 18.0 : 28.0;
          final topStart = math.max(165.0, math.min(height * .24, 235.0));
          final availableWidth = math.max(1.0, width - leftSafe - rightSafe - bubbleSize);
          final availableHeight = math.max(220.0, height - topStart - 96.0);
          final wave = math.sin((_controller.value * math.pi * 2) + 1.35);
          final drift = math.cos((_controller.value * math.pi * 2) + .9);
          final baseLeft = leftSafe + (availableWidth * _horizontalFactor);
          final baseTop = topStart + (availableHeight * _verticalFactor);
          final left = math.min(math.max(leftSafe, baseLeft + (wave * 14)), width - rightSafe - bubbleSize);
          final top = math.min(math.max(112.0, baseTop + (drift * 12)), height - 105);

          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: left,
                top: top,
                child: IgnorePointer(
                  ignoring: !_bubbleVisible,
                  child: AnimatedOpacity(
                    opacity: _bubbleVisible ? 1 : 0,
                    duration: AppMotion.fast,
                    curve: AppMotion.emphasized,
                    child: AnimatedScale(
                      scale: _bubbleVisible ? 1 : .78,
                      duration: AppMotion.fast,
                      curve: AppMotion.emphasized,
                      child: _SavingsSuggestionBubble(
                        suggestion: visibleSuggestion,
                        selected: _poppedId == visibleSuggestion.id,
                        onTap: () => _popBubble(visibleSuggestion),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SavingsSuggestionBubble extends StatelessWidget {
  const _SavingsSuggestionBubble({required this.suggestion, required this.selected, required this.onTap});

  final SavingsPurchaseSuggestion suggestion;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = colorFromHex(suggestion.color, fallback: kSleekAccent);
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedScale(
      scale: selected ? .82 : 1,
      duration: AppMotion.fast,
      curve: AppMotion.emphasized,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          width: 74,
          height: 74,
          decoration: BoxDecoration(
            color: selected ? color.withOpacity(.30) : (dark ? const Color(0xEE10191D) : Colors.white.withOpacity(.96)),
            shape: BoxShape.circle,
            border: Border.all(color: selected ? color.withOpacity(.78) : color.withOpacity(.36), width: selected ? 2 : 1.2),
            boxShadow: [
              BoxShadow(color: color.withOpacity(selected ? .42 : .26), blurRadius: selected ? 30 : 22, offset: const Offset(0, 10)),
              BoxShadow(color: Colors.black.withOpacity(dark ? .28 : .10), blurRadius: 18, offset: const Offset(0, 12)),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withOpacity(.16),
                  border: Border.all(color: scheme.outline.withOpacity(dark ? .10 : .20)),
                ),
              ),
              Text(
                '?',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w900,
                      height: 1,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SavingsSuggestionDetailDialog extends StatelessWidget {
  const SavingsSuggestionDetailDialog({super.key, required this.suggestion});

  final SavingsPurchaseSuggestion suggestion;

  @override
  Widget build(BuildContext context) {
    final color = colorFromHex(suggestion.color, fallback: kSleekAccent);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            iconBubble(context, suggestion.iconName, suggestion.color, size: 58),
            const SizedBox(height: 14),
            Text(suggestion.title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 12),
            _SuggestionDetailRow(icon: Icons.price_change_rounded, title: 'Estimated cost', body: suggestion.costRange, color: color),
            _SuggestionDetailRow(icon: Icons.psychology_rounded, title: 'Why this fits', body: suggestion.reason, color: color),
            _SuggestionDetailRow(icon: Icons.savings_rounded, title: 'Savings fit', body: suggestion.savingsFit, color: color),
            const SizedBox(height: 8),
            Text('This is an optional spending idea, not financial advice. Only buy if it fits your actual needs and savings goal.', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700)),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Dismiss'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuggestionDetailRow extends StatelessWidget {
  const _SuggestionDetailRow({required this.icon, required this.title, required this.body, required this.color});

  final IconData icon;
  final String title;
  final String body;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh.withOpacity(.52),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(.12)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w900)),
                  const SizedBox(height: 3),
                  Text(body, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showSavingsSuggestionProfileSheet(BuildContext context, {bool firstRun = false}) async {
  await showKoinlyPopup<void>(
    context,
    maxWidth: 560,
    maxHeight: 720,
    barrierDismissible: !firstRun,
    child: SavingsSuggestionProfileEditor(firstRun: firstRun),
  );
}

class SavingsSuggestionProfileEditor extends StatefulWidget {
  const SavingsSuggestionProfileEditor({super.key, this.firstRun = false});

  final bool firstRun;

  @override
  State<SavingsSuggestionProfileEditor> createState() => _SavingsSuggestionProfileEditorState();
}

class _SavingsSuggestionProfileEditorState extends State<SavingsSuggestionProfileEditor> {
  final hobby = TextEditingController();
  final occupation = TextEditingController();
  final age = TextEditingController();
  final goal = TextEditingController();
  final preference = TextEditingController();
  final extra = TextEditingController();

  @override
  void initState() {
    super.initState();
    final profile = context.read<AppController>().savingsSuggestionProfile;
    hobby.text = profile.hobby;
    occupation.text = profile.occupation;
    age.text = profile.age <= 0 ? '' : '${profile.age}';
    goal.text = profile.savingsGoal;
    preference.text = profile.spendingPreference;
    extra.text = profile.extraDetails;
  }

  @override
  void dispose() {
    hobby.dispose();
    occupation.dispose();
    age.dispose();
    goal.dispose();
    preference.dispose();
    extra.dispose();
    super.dispose();
  }

  Future<void> _save({bool skip = false}) async {
    final profile = skip
        ? SavingsSuggestionProfile.empty.copyWith(completed: true, updatedOn: DateTime.now())
        : SavingsSuggestionProfile(
            completed: true,
            hobby: hobby.text.trim(),
            occupation: occupation.text.trim(),
            age: int.tryParse(age.text.trim()) ?? 0,
            savingsGoal: goal.text.trim(),
            spendingPreference: preference.text.trim(),
            extraDetails: extra.text.trim(),
            updatedOn: DateTime.now(),
          );
    await context.read<AppController>().saveSavingsSuggestionProfile(profile);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.firstRun ? 'Savings suggestion profile' : 'Edit suggestion profile', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            Text('Used only to personalize optional purchase ideas. Savings transfers remain internal and do not count as income or expense.', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            TextField(controller: hobby, decoration: const InputDecoration(labelText: 'Hobby', hintText: 'Gaming, anime, reading, travel...')),
            const SizedBox(height: 10),
            TextField(controller: occupation, decoration: const InputDecoration(labelText: 'Occupation', hintText: 'Student, worker, creator...')),
            const SizedBox(height: 10),
            TextField(controller: age, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Age')),
            const SizedBox(height: 10),
            TextField(controller: goal, decoration: const InputDecoration(labelText: 'Savings goal', hintText: 'Emergency fund, phone, PC, trip...')),
            const SizedBox(height: 10),
            TextField(controller: preference, decoration: const InputDecoration(labelText: 'Spending preference', hintText: 'Careful, balanced, hobby-first...')),
            const SizedBox(height: 10),
            TextField(controller: extra, minLines: 2, maxLines: 3, decoration: const InputDecoration(labelText: 'Other details optional')),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(child: OutlinedButton(onPressed: () => _save(skip: true), child: Text(widget.firstRun ? 'Skip' : 'Reset'))),
                const SizedBox(width: 10),
                Expanded(flex: 2, child: FilledButton(onPressed: _save, child: const Text('Save profile'))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class AccountReorderScreen extends StatefulWidget {
  const AccountReorderScreen({super.key, this.filterType});
  final AccountType? filterType;

  @override
  State<AccountReorderScreen> createState() => _AccountReorderScreenState();
}

class _AccountReorderScreenState extends State<AccountReorderScreen> {
  late List<Account> items;

  bool _matches(Account account) {
    if (widget.filterType == AccountType.savings) return account.type == AccountType.savings;
    return account.type != AccountType.savings;
  }

  @override
  void initState() {
    super.initState();
    items = context.read<AppController>().accounts.where(_matches).toList();
  }

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: widget.filterType == AccountType.savings ? 'Reorder savings accounts' : 'Reorder accounts',
      actions: [
        IconButton(
          onPressed: () async {
            await context.read<AppController>().reorderAccounts(items);
            if (context.mounted) Navigator.pop(context);
          },
          icon: const Icon(Icons.check_rounded),
        )
      ],
      child: ReorderableListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        itemCount: items.length,
        onReorder: (oldIndex, newIndex) {
          setState(() {
            if (newIndex > oldIndex) newIndex -= 1;
            final item = items.removeAt(oldIndex);
            items.insert(newIndex, item);
          });
        },
        itemBuilder: (context, index) => Padding(
          key: ValueKey(items[index].id),
          padding: const EdgeInsets.only(bottom: 10),
          child: AccountTile(account: items[index]),
        ),
      ),
    );
  }
}

Future<void> showAccountEditor(
  BuildContext context, {
  Account? account,
  AccountType initialType = AccountType.regular,
  List<AccountType>? allowedTypes,
}) async {
  await showKoinlyPopup<void>(
    context,
    maxWidth: 560,
    maxHeight: 720,
    child: AccountEditor(account: account, initialType: initialType, allowedTypes: allowedTypes),
  );
}

class AccountEditor extends StatefulWidget {
  const AccountEditor({super.key, this.account, this.initialType = AccountType.regular, this.allowedTypes});
  final Account? account;
  final AccountType initialType;
  final List<AccountType>? allowedTypes;

  @override
  State<AccountEditor> createState() => _AccountEditorState();
}

class _AccountEditorState extends State<AccountEditor> {
  final name = TextEditingController();
  final amount = TextEditingController();
  final creditLimit = TextEditingController();
  AccountType type = AccountType.regular;
  String icon = 'wallet';
  String color = '#78D8E8';

  List<AccountType> get allowedTypes => widget.allowedTypes ?? AccountType.values;

  List<SleekPillOption<AccountType>> get _typeOptions {
    return allowedTypes.map((accountType) {
      switch (accountType) {
        case AccountType.regular:
          return const SleekPillOption(value: AccountType.regular, label: 'Regular', icon: Icons.account_balance_wallet_rounded);
        case AccountType.credit:
          return const SleekPillOption(value: AccountType.credit, label: 'Credit', icon: Icons.credit_card_rounded);
        case AccountType.savings:
          return const SleekPillOption(value: AccountType.savings, label: 'Savings', icon: Icons.savings_rounded);
      }
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    final a = widget.account;
    if (a != null) {
      name.text = a.name;
      amount.text = a.amount.toStringAsFixed(2);
      creditLimit.text = a.creditLimit.toStringAsFixed(2);
      type = allowedTypes.contains(a.type) ? a.type : allowedTypes.first;
      icon = a.iconName;
      color = a.iconColor;
    } else {
      type = allowedTypes.contains(widget.initialType) ? widget.initialType : allowedTypes.first;
      if (type == AccountType.savings) {
        name.text = 'Savings Account';
        icon = 'savings';
        color = '#A6E3A1';
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 14),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.account == null ? 'Create account' : 'Edit account', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 18),
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Account name')),
            const SizedBox(height: 12),
            SleekPillSelector<AccountType>(
              options: _typeOptions,
              selected: type,
              onChanged: (v) => setState(() {
                type = v;
                if (v == AccountType.savings && icon == 'wallet') {
                  icon = 'savings';
                  color = '#A6E3A1';
                }
              }),
            ),
            const SizedBox(height: 12),
            TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Balance')),
            if (type == AccountType.savings) ...[
              const SizedBox(height: 8),
              Text(
                'Changing this balance updates total accounts only. It does not create income, expense, or transaction history.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
              ),
            ],
            if (type == AccountType.credit) ...[
              const SizedBox(height: 12),
              TextField(controller: creditLimit, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Credit limit')),
            ],
            const SizedBox(height: 12),
            IconColorPicker(selectedIcon: icon, selectedColor: color, onChanged: (i, c) => setState(() { icon = i; color = c; })),
            const SizedBox(height: 18),
            Row(
              children: [
                if (widget.account != null)
                  Expanded(child: OutlinedButton(onPressed: () async { await state.deleteAccount(widget.account!.id); if (context.mounted) Navigator.pop(context); }, child: const Text('Delete'))),
                if (widget.account != null) const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: () async {
                      if (name.text.trim().isEmpty) return;
                      final now = DateTime.now();
                      final a = Account(
                        id: widget.account?.id ?? _uuid.v4(),
                        name: name.text.trim(),
                        type: type,
                        iconName: icon,
                        iconColor: color,
                        amount: double.tryParse(amount.text) ?? 0,
                        creditLimit: type == AccountType.credit ? (double.tryParse(creditLimit.text) ?? 0) : 0,
                        sequence: widget.account?.sequence ?? state.accounts.length,
                        createdOn: widget.account?.createdOn ?? now,
                        updatedOn: now,
                      );
                      await state.saveAccount(a);
                      if (context.mounted) Navigator.pop(context);
                    },
                    child: const Text('Save'),
                  ),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }
}


class IconColorPicker extends StatelessWidget {
  const IconColorPicker({super.key, required this.selectedIcon, required this.selectedColor, required this.onChanged});
  final String selectedIcon;
  final String selectedColor;
  final void Function(String icon, String color) onChanged;

  static const icons = [
    'wallet', 'credit_card', 'bank', 'savings', 'cash', 'atm', 'receipt', 'calculator',
    'apparel', 'shopping_bag', 'cart', 'store', 'food', 'groceries', 'coffee', 'fastfood',
    'health', 'hospital', 'medicine', 'favorite', 'leisure', 'games', 'movie', 'music',
    'sports', 'fitness', 'book', 'school', 'car', 'bus', 'train', 'flight', 'origami_bird', 'anime', 'manga', 'collectibles', 'headphones', 'keyboard', 'laptop', 'monitor', 'mic', 'video', 'art', 'subscription', 'fuel',
    'home', 'house', 'apartment', 'utilities', 'water', 'wifi', 'phone', 'bolt',
    'gift', 'celebration', 'travel', 'pets', 'baby', 'beauty', 'salary', 'work',
    'business', 'investment', 'money', 'exchange', 'coupon', 'handshake', 'donation',
    'security', 'insurance', 'tools', 'construction', 'cleaning', 'laundry', 'parking',
    'calendar', 'time', 'flag', 'profile', 'loan_given', 'loan_taken'
  ];
  static const colors = [
    '#78D8E8', '#38BDF8', '#0EA5E9', '#2563EB', '#1D4ED8', '#6366F1', '#8B5CF6', '#A855F7',
    '#D946EF', '#EC4899', '#F472B6', '#FB7185', '#EF4444', '#F97316', '#FB923C', '#F59E0B',
    '#FBC879', '#FACC15', '#A3E635', '#84CC16', '#22C55E', '#16A34A', '#10B981', '#14B8A6',
    '#2DD4BF', '#86E3CE', '#A6E3A1', '#89A7FF', '#B4A5FF', '#C4B5FD', '#F5A3A3', '#FFB5D0',
    '#FFB86B', '#94A3B8', '#64748B', '#475569', '#334155', '#1F2937', '#111827', '#F8FAFC'
  ];

  Future<void> _pickColor(BuildContext context) async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => ColorSelectionPage(selectedColor: selectedColor)),
    );
    if (result != null) onChanged(selectedIcon, result);
  }

  Future<void> _pickIcon(BuildContext context) async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => IconSelectionPage(selectedIcon: selectedIcon, selectedColor: selectedColor)),
    );
    if (result != null) onChanged(result, selectedColor);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 10),
          child: Text(
            'APPEARANCE',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  letterSpacing: 3,
                  fontWeight: FontWeight.w900,
                  color: colorScheme.onSurface.withOpacity(.82),
                ),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: _AppearanceButton(
                label: 'Color',
                onTap: () => _pickColor(context),
                preview: _ColorPreviewDot(color: selectedColor),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _AppearanceButton(
                label: 'Icon',
                onTap: () => _pickIcon(context),
                preview: _IconPreviewDot(icon: selectedIcon, color: selectedColor),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _AppearanceButton extends StatelessWidget {
  const _AppearanceButton({required this.label, required this.preview, required this.onTap});
  final String label;
  final Widget preview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerHighest.withOpacity(.52),
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 104),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: colorScheme.outline.withOpacity(.28), width: 1),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(.10), blurRadius: 18, offset: const Offset(0, 8))],
          ),
          child: Row(
            children: [
              preview,
              const SizedBox(width: 14),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    label,
                    maxLines: 1,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Icon(Icons.edit_rounded, color: colorScheme.onSurface.withOpacity(.72)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ColorPreviewDot extends StatelessWidget {
  const _ColorPreviewDot({required this.color});
  final String color;

  @override
  Widget build(BuildContext context) {
    final c = colorFromHex(color, fallback: Theme.of(context).colorScheme.primary);
    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        color: c,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).colorScheme.onSurface.withOpacity(.10), width: 3),
        boxShadow: [BoxShadow(color: c.withOpacity(.35), blurRadius: 6, offset: const Offset(0, 2))],
      ),
    );
  }
}

class _IconPreviewDot extends StatelessWidget {
  const _IconPreviewDot({required this.icon, required this.color});
  final String icon;
  final String color;

  @override
  Widget build(BuildContext context) {
    final c = colorFromHex(color, fallback: Theme.of(context).colorScheme.primary);
    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(color: c, shape: BoxShape.circle),
      child: Center(child: iconGlyph(context, icon, color: Colors.white, size: 30, imageBackground: Colors.white.withOpacity(.92))),
    );
  }
}

class ColorSelectionPage extends StatelessWidget {
  const ColorSelectionPage({super.key, required this.selectedColor});
  final String selectedColor;

  String _normalizeColor(String value) {
    final cleaned = value.trim().replaceAll('#', '').replaceAll('0x', '').replaceAll('0X', '');
    final rgb = cleaned.length == 8 && cleaned.toUpperCase().startsWith('FF') ? cleaned.substring(2) : cleaned;
    if (RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(rgb)) return '#${rgb.toUpperCase()}';
    return '';
  }

  Future<String?> _showCustomColorOptions(BuildContext context) async {
    final initial = _normalizeColor(selectedColor).isEmpty ? '#78D8E8' : _normalizeColor(selectedColor);

    final choice = await showKoinlyPopup<String>(
      context,
      maxWidth: 460,
      maxHeight: 420,
      child: Builder(
        builder: (dialogContext) {
          final dark = Theme.of(dialogContext).brightness == Brightness.dark;
          final handleColor = dark ? const Color(0xFF43545B) : const Color(0xFFB7C8CE);
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(color: handleColor, borderRadius: BorderRadius.circular(999)),
                ),
                const SizedBox(height: 18),
                Text(
                  'Custom color',
                  style: Theme.of(dialogContext).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 6),
                Text(
                  'Choose how you want to create a custom color.',
                  textAlign: TextAlign.center,
                  style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 16),
                _CustomColorOptionCard(
                  icon: Icons.palette_rounded,
                  title: 'Color picker',
                  subtitle: 'Use color wheel, brightness, and HEX input',
                  onTap: () => Navigator.pop(dialogContext, 'wheel'),
                ),
                const SizedBox(height: 10),
                _CustomColorOptionCard(
                  icon: Icons.photo_library_rounded,
                  title: 'Pick from photo',
                  subtitle: 'Upload a photo and tap any pixel color',
                  onTap: () => Navigator.pop(dialogContext, 'photo'),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Cancel'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );

    if (!context.mounted || choice == null) return null;
    if (choice == 'wheel') {
      return Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => ColorWheelPickerPage(initialColor: initial)),
      );
    }
    if (choice == 'photo') {
      return Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => PhotoColorPickerPage(initialColor: initial)),
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final selectedNormalized = _normalizeColor(selectedColor);
    final presetColors = IconColorPicker.colors.map(_normalizeColor).where((c) => c.isNotEmpty).toList();
    final customSelected = selectedNormalized.isNotEmpty && !presetColors.map((c) => c.toLowerCase()).contains(selectedNormalized.toLowerCase());

    return PageScaffold(
      title: 'Choose color',
      subtitle: 'Select the appearance color',
      child: ResponsiveContent(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final columns = width < 360
                ? 4
                : width < 500
                    ? 5
                    : 6;
            final spacing = width < 360 ? 12.0 : 14.0;
            final itemSize = ((width - (spacing * (columns - 1))) / columns).clamp(52.0, 68.0).toDouble();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Material(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(.52),
                  borderRadius: BorderRadius.circular(22),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(22),
                    onTap: () async {
                      final custom = await _showCustomColorOptions(context);
                      if (custom != null && context.mounted) Navigator.pop(context, custom);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: customSelected ? kSleekAccent.withOpacity(.45) : Theme.of(context).colorScheme.outline.withOpacity(.24), width: 1),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: customSelected ? colorFromHex(selectedNormalized) : kSleekAccent.withOpacity(.18),
                              shape: BoxShape.circle,
                              border: Border.all(color: kSleekAccent.withOpacity(.45), width: 1.5),
                              boxShadow: customSelected ? [BoxShadow(color: colorFromHex(selectedNormalized).withOpacity(.32), blurRadius: 16)] : null,
                            ),
                            child: Icon(customSelected ? Icons.check_rounded : Icons.color_lens_rounded, color: Colors.white),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Custom color', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
                                const SizedBox(height: 2),
                                Text(
                                  customSelected ? selectedNormalized : 'Color picker or pick from photo',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right_rounded),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: presetColors.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: spacing,
                    crossAxisSpacing: spacing,
                    childAspectRatio: 1,
                  ),
                  itemBuilder: (context, index) {
                    final color = presetColors[index];
                    final selected = selectedNormalized.toLowerCase() == color.toLowerCase();
                    return Center(
                      child: _ColorChoiceDot(
                        color: color,
                        selected: selected,
                        size: itemSize,
                        onTap: () => Navigator.pop(context, color),
                      ),
                    );
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _CustomColorOptionCard extends StatelessWidget {
  const _CustomColorOptionCard({required this.icon, required this.title, required this.subtitle, required this.onTap});

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(.50),
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(.28), width: .9),
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: kSleekAccent.withOpacity(.16),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: kSleekAccent.withOpacity(.24)),
                ),
                child: Icon(icon, color: kSleekAccent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

class ColorWheelPickerPage extends StatefulWidget {
  const ColorWheelPickerPage({super.key, required this.initialColor});
  final String initialColor;

  @override
  State<ColorWheelPickerPage> createState() => _ColorWheelPickerPageState();
}

class _ColorWheelPickerPageState extends State<ColorWheelPickerPage> {
  late Color selectedColor;
  late TextEditingController hexController;
  double hue = 185;
  double saturation = .65;
  double value = .86;

  @override
  void initState() {
    super.initState();
    selectedColor = colorFromHex(widget.initialColor, fallback: kSleekAccent);
    final hsv = HSVColor.fromColor(selectedColor);
    hue = hsv.hue;
    saturation = hsv.saturation;
    value = hsv.value;
    hexController = TextEditingController(text: _hex(selectedColor));
  }

  @override
  void dispose() {
    hexController.dispose();
    super.dispose();
  }

  String _hex(Color color) => '#${color.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  void _setColor(Color color, {bool updateHsv = true}) {
    setState(() {
      selectedColor = color.withAlpha(255);
      if (updateHsv) {
        final hsv = HSVColor.fromColor(selectedColor);
        hue = hsv.hue;
        saturation = hsv.saturation;
        value = hsv.value;
      }
      hexController.text = _hex(selectedColor);
    });
  }

  void _setFromHex(String input) {
    final cleaned = input.trim().replaceAll('#', '');
    if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(cleaned)) return;
    _setColor(Color(int.parse('FF$cleaned', radix: 16)));
  }

  @override
  Widget build(BuildContext context) {
    final validHex = RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(hexController.text);
    return PageScaffold(
      title: 'Color picker',
      subtitle: 'Create a custom color',
      child: ResponsiveContent(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExpressiveCard(
              child: Column(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 78,
                    height: 78,
                    decoration: BoxDecoration(
                      color: selectedColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white.withOpacity(.35), width: 2),
                      boxShadow: [BoxShadow(color: selectedColor.withOpacity(.40), blurRadius: 22, spreadRadius: 1)],
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: hexController,
                    textAlign: TextAlign.center,
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F#]')),
                      LengthLimitingTextInputFormatter(7),
                    ],
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.tag_rounded),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.check_rounded),
                        onPressed: validHex ? () => _setFromHex(hexController.text) : null,
                      ),
                      labelText: 'HEX color',
                      errorText: validHex ? null : 'Use #RRGGBB',
                    ),
                    onChanged: _setFromHex,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            ExpressiveCard(
              child: Column(
                children: [
                  AspectRatio(
                    aspectRatio: 1,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final wheelSize = Size(constraints.maxWidth, constraints.maxHeight);
                        return GestureDetector(
                          onPanDown: (details) => _pickFromWheel(details.localPosition, wheelSize),
                          onPanUpdate: (details) => _pickFromWheel(details.localPosition, wheelSize),
                          onTapDown: (details) => _pickFromWheel(details.localPosition, wheelSize),
                          child: CustomPaint(
                            painter: _HueSaturationWheelPainter(value: value),
                            foregroundPainter: _HueWheelHandlePainter(hue: hue, saturation: saturation),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  _ValueSlider(
                    color: selectedColor,
                    value: value,
                    onChanged: (v) {
                      setState(() => value = v);
                      _setColor(HSVColor.fromAHSV(1, hue, saturation, value).toColor(), updateHsv: false);
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: validHex ? () => Navigator.pop(context, _hex(selectedColor)) : null,
              child: const Text('Apply color'),
            ),
          ],
        ),
      ),
    );
  }

  void _pickFromWheel(Offset localPosition, Size wheelSize) {
    final size = wheelSize.shortestSide;
    final center = Offset(wheelSize.width / 2, wheelSize.height / 2);
    final dx = localPosition.dx - center.dx;
    final dy = localPosition.dy - center.dy;
    final radius = math.sqrt(dx * dx + dy * dy);
    final maxRadius = size / 2;
    if (radius > maxRadius) return;
    final angle = math.atan2(dy, dx);
    hue = (angle * 180 / math.pi + 360) % 360;
    saturation = (radius / maxRadius).clamp(0.0, 1.0).toDouble();
    _setColor(HSVColor.fromAHSV(1, hue, saturation, value).toColor(), updateHsv: false);
  }
}

class PhotoColorPickerPage extends StatefulWidget {
  const PhotoColorPickerPage({super.key, required this.initialColor});
  final String initialColor;

  @override
  State<PhotoColorPickerPage> createState() => _PhotoColorPickerPageState();
}

class _PhotoColorPickerPageState extends State<PhotoColorPickerPage> {
  late Color selectedColor;
  Uint8List? bytes;
  ui.Image? decodedImage;
  Uint8List? pixels;
  Offset? handle;

  @override
  void initState() {
    super.initState();
    selectedColor = colorFromHex(widget.initialColor, fallback: kSleekAccent);
  }

  @override
  void dispose() {
    decodedImage?.dispose();
    super.dispose();
  }

  String _hex(Color color) => '#${color.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  Future<void> _pickPhoto() async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    if (picked == null) return;
    final data = picked.files.single.bytes ?? (picked.files.single.path == null ? null : await File(picked.files.single.path!).readAsBytes());
    if (data == null) return;

    final codec = await ui.instantiateImageCodec(data);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);

    decodedImage?.dispose();
    setState(() {
      bytes = data;
      decodedImage = image;
      pixels = byteData?.buffer.asUint8List();
      handle = null;
    });
  }

  void _sampleColor(Offset pos, Size size) {
    final image = decodedImage;
    final raw = pixels;
    if (image == null || raw == null) return;

    final scale = math.min(size.width / image.width, size.height / image.height);
    final displayedWidth = image.width * scale;
    final displayedHeight = image.height * scale;
    final offset = Offset((size.width - displayedWidth) / 2, (size.height - displayedHeight) / 2);

    if (pos.dx < offset.dx || pos.dy < offset.dy || pos.dx > offset.dx + displayedWidth || pos.dy > offset.dy + displayedHeight) return;

    final x = ((pos.dx - offset.dx) / scale).floor().clamp(0, image.width - 1);
    final y = ((pos.dy - offset.dy) / scale).floor().clamp(0, image.height - 1);
    final index = ((y * image.width + x) * 4).toInt();
    if (index + 3 >= raw.length) return;

    setState(() {
      selectedColor = Color.fromARGB(255, raw[index], raw[index + 1], raw[index + 2]);
      handle = pos;
    });
  }

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: 'Pick from photo',
      subtitle: 'Tap or drag on a photo to sample color',
      child: ResponsiveContent(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExpressiveCard(
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      color: selectedColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white.withOpacity(.35), width: 2),
                      boxShadow: [BoxShadow(color: selectedColor.withOpacity(.40), blurRadius: 18)],
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_hex(selectedColor), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
                        const SizedBox(height: 3),
                        Text('Selected custom color', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _pickPhoto,
              icon: const Icon(Icons.photo_library_rounded),
              label: Text(bytes == null ? 'Upload photo' : 'Change photo'),
            ),
            const SizedBox(height: 14),
            ExpressiveCard(
              padding: const EdgeInsets.all(14),
              child: bytes == null
                  ? EmptyCard(
                      icon: Icons.photo_library_rounded,
                      title: 'No photo selected',
                      body: 'Upload a photo, then tap or drag on it to pick a color.',
                    )
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: Container(
                        height: 300,
                        color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF0B1417) : const Color(0xFFF5FAFB),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final size = Size(constraints.maxWidth, constraints.maxHeight);
                            return GestureDetector(
                              onTapDown: (details) => _sampleColor(details.localPosition, size),
                              onPanDown: (details) => _sampleColor(details.localPosition, size),
                              onPanUpdate: (details) => _sampleColor(details.localPosition, size),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Image.memory(bytes!, fit: BoxFit.contain),
                                  if (handle != null)
                                    Positioned(
                                      left: handle!.dx - 12,
                                      top: handle!.dy - 12,
                                      child: Container(
                                        width: 24,
                                        height: 24,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          border: Border.all(color: Colors.white, width: 3),
                                          boxShadow: [BoxShadow(color: Colors.black.withOpacity(.45), blurRadius: 8)],
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: () => Navigator.pop(context, _hex(selectedColor)),
              child: const Text('Apply color'),
            ),
          ],
        ),
      ),
    );
  }
}

class _HueSaturationWheelPainter extends CustomPainter {
  const _HueSaturationWheelPainter({required this.value});
  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = SweepGradient(
          colors: const [
            Color(0xFFFF0000),
            Color(0xFFFFFF00),
            Color(0xFF00FF00),
            Color(0xFF00FFFF),
            Color(0xFF0000FF),
            Color(0xFFFF00FF),
            Color(0xFFFF0000),
          ],
        ).createShader(rect),
    );

    canvas.drawCircle(
      center,
      radius,
      Paint()..shader = RadialGradient(colors: [Colors.white, Colors.white.withOpacity(0)]).createShader(rect),
    );

    if (value < 1) {
      canvas.drawCircle(center, radius, Paint()..color = Colors.black.withOpacity(1 - value));
    }

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withOpacity(.22),
    );
  }

  @override
  bool shouldRepaint(covariant _HueSaturationWheelPainter oldDelegate) => oldDelegate.value != value;
}

class _HueWheelHandlePainter extends CustomPainter {
  const _HueWheelHandlePainter({required this.hue, required this.saturation});
  final double hue;
  final double saturation;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.shortestSide / 2;
    final angle = hue * math.pi / 180;
    final handle = Offset(
      radius + math.cos(angle) * radius * saturation,
      radius + math.sin(angle) * radius * saturation,
    );
    canvas.drawCircle(handle, 9, Paint()..color = Colors.white);
    canvas.drawCircle(
      handle,
      6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.black.withOpacity(.55),
    );
  }

  @override
  bool shouldRepaint(covariant _HueWheelHandlePainter oldDelegate) => oldDelegate.hue != hue || oldDelegate.saturation != saturation;
}

class _ValueSlider extends StatelessWidget {
  const _ValueSlider({required this.color, required this.value, required this.onChanged});
  final Color color;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Brightness', style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800, color: kSleekMuted)),
        const SizedBox(height: 8),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 16,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
            activeTrackColor: color,
            inactiveTrackColor: Colors.white.withOpacity(.12),
            thumbColor: Colors.white,
          ),
          child: Slider(value: value, min: 0, max: 1, onChanged: onChanged),
        ),
      ],
    );
  }
}

class _ColorChoiceDot extends StatelessWidget {
  const _ColorChoiceDot({required this.color, required this.selected, required this.size, required this.onTap});

  final String color;
  final bool selected;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = colorFromHex(color, fallback: Theme.of(context).colorScheme.primary);
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: size,
        height: size,
        padding: EdgeInsets.all(selected ? 5 : 4),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Theme.of(context).colorScheme.onSurface : Theme.of(context).colorScheme.outline.withOpacity(.28),
            width: selected ? 3.2 : 1.2,
          ),
        ),
        child: Container(
          decoration: BoxDecoration(
            color: c,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: c.withOpacity(selected ? .42 : .18), blurRadius: selected ? 14 : 8, spreadRadius: selected ? 1 : 0)],
          ),
          child: selected ? const Icon(Icons.check_rounded, color: Colors.white, size: 28) : null,
        ),
      ),
    );
  }
}


class IconSelectionPage extends StatelessWidget {
  const IconSelectionPage({super.key, required this.selectedIcon, required this.selectedColor});
  final String selectedIcon;
  final String selectedColor;

  @override
  Widget build(BuildContext context) {
    final selectedColorValue = colorFromHex(selectedColor, fallback: Theme.of(context).colorScheme.primary);
    return PageScaffold(
      title: 'Choose icon',
      subtitle: 'Select the account or category icon',
      child: ResponsiveContent(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: IconColorPicker.icons.map((icon) {
            final selected = selectedIcon == icon;
            return Material(
              color: selected ? selectedColorValue.withOpacity(.22) : Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(.48),
              borderRadius: BorderRadius.circular(20),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => Navigator.pop(context, icon),
                child: Container(
                  width: 62,
                  height: 62,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: selected ? selectedColorValue : Theme.of(context).colorScheme.outline.withOpacity(.30),
                      width: selected ? 2.4 : 1.2,
                    ),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      iconGlyph(context, icon, color: selected ? selectedColorValue : Theme.of(context).colorScheme.onSurface, size: 28, imageBackground: Colors.white.withOpacity(.92)),
                      if (selected)
                        Positioned(
                          right: 5,
                          bottom: 5,
                          child: Icon(Icons.check_circle_rounded, size: 16, color: selectedColorValue),
                        ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}


class CategoryTile extends StatelessWidget {
  const CategoryTile({super.key, required this.category, this.trailing, this.onTap});
  final Category category;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ExpressiveCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: iconBubble(context, category.iconName, category.iconColor),
        title: Text(category.name, style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(enumName(category.type)),
        trailing: trailing,
        onTap: onTap,
      ),
    );
  }
}

Future<void> showCategoryEditor(BuildContext context, {Category? category, CategoryType? initialType}) async {
  await showKoinlyPopup<void>(
    context,
    maxWidth: 560,
    maxHeight: 720,
    child: CategoryEditor(category: category, initialType: initialType),
  );
}

class CategoryEditor extends StatefulWidget {
  const CategoryEditor({super.key, this.category, this.initialType});
  final Category? category;
  final CategoryType? initialType;

  @override
  State<CategoryEditor> createState() => _CategoryEditorState();
}

class _CategoryEditorState extends State<CategoryEditor> {
  final name = TextEditingController();
  CategoryType type = CategoryType.expense;
  String icon = 'category';
  String color = '#78D8E8';

  @override
  void initState() {
    super.initState();
    final c = widget.category;
    if (c != null) {
      name.text = c.name;
      type = c.type;
      icon = c.iconName;
      color = c.iconColor;
    } else {
      type = widget.initialType ?? CategoryType.expense;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 14),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.category == null ? 'Create category' : 'Edit category', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 18),
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Category name')),
            const SizedBox(height: 12),
            SleekPillSelector<CategoryType>(
              options: const [
                SleekPillOption(value: CategoryType.expense, label: 'Expense', icon: Icons.north_east_rounded),
                SleekPillOption(value: CategoryType.income, label: 'Income', icon: Icons.south_west_rounded),
              ],
              selected: type,
              onChanged: (v) => setState(() => type = v),
            ),
            const SizedBox(height: 12),
            IconColorPicker(selectedIcon: icon, selectedColor: color, onChanged: (i, c) => setState(() { icon = i; color = c; })),
            const SizedBox(height: 18),
            Row(children: [
              if (widget.category != null) Expanded(child: OutlinedButton(onPressed: () async { await state.deleteCategory(widget.category!.id); if (context.mounted) Navigator.pop(context); }, child: const Text('Delete'))),
              if (widget.category != null) const SizedBox(width: 12),
              Expanded(flex: 2, child: FilledButton(onPressed: () async {
                if (name.text.trim().isEmpty) return;
                final now = DateTime.now();
                final category = Category(id: widget.category?.id ?? _uuid.v4(), name: name.text.trim(), type: type, iconName: icon, iconColor: color, createdOn: widget.category?.createdOn ?? now, updatedOn: now);
                await state.saveCategory(category);
                if (context.mounted) Navigator.pop(context);
              }, child: const Text('Save'))),
            ]),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Transactions and filters
// -----------------------------------------------------------------------------

class TransactionListScreen extends StatelessWidget {
  const TransactionListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final txs = state.filteredTransactions();
    return PageScaffold(
      title: 'Transaction',
      subtitle: '${txs.length} records • ${state.activeRange().label}',
      actions: [
        IconButton(onPressed: () => showDateRangeSheet(context), icon: const Icon(Icons.date_range_rounded)),
        IconButton(onPressed: () => showFilterSheet(context), icon: const Icon(Icons.filter_alt_rounded)),
      ],
      child: ResponsiveListContent(
        header: [ActiveFilterChips(state: state)],
        itemCount: txs.length,
        empty: EmptyCard(icon: Icons.receipt_long_rounded, title: 'No transactions', body: 'Create a transaction or change filters.', action: () => showTransactionEditor(context), actionLabel: 'Add transaction'),
        itemBuilder: (context, index) => TransactionTile(tx: txs[index]),
      ),
    );
  }
}

class ActiveFilterChips extends StatelessWidget {
  const ActiveFilterChips({super.key, required this.state});
  final AppController state;

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[];
    for (final id in state.filterAccountIds) {
      chips.add(InputChip(label: Text(state.accountOf(id)?.name ?? 'Account'), onDeleted: () => state.saveFilters(accounts: state.filterAccountIds.where((e) => e != id).toList())));
    }
    for (final id in state.filterCategoryIds) {
      chips.add(InputChip(label: Text(state.categoryOf(id)?.name ?? 'Category'), onDeleted: () => state.saveFilters(categories: state.filterCategoryIds.where((e) => e != id).toList())));
    }
    for (final type in state.filterTypes) {
      chips.add(InputChip(label: Text(enumName(type)), onDeleted: () => state.saveFilters(types: state.filterTypes.where((e) => e != type).toList())));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    chips.add(TextButton(onPressed: state.clearFilters, child: const Text('Clear all')));
    return Padding(padding: const EdgeInsets.only(bottom: 12), child: Wrap(spacing: 8, runSpacing: 8, children: chips));
  }
}

class TransactionTile extends StatelessWidget {
  const TransactionTile({super.key, required this.tx});
  final MoneyTransaction tx;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final category = state.categoryOf(tx.categoryId);
    final account = state.accountOf(tx.fromAccountId);
    final toAccount = tx.toAccountId == null ? null : state.accountOf(tx.toAccountId!);
    final amountPrefix = tx.type == MoneyTransactionType.expense ? '-' : tx.type == MoneyTransactionType.income ? '+' : '';
    final amountColor = tx.type == MoneyTransactionType.expense ? kSleekExpense : tx.type == MoneyTransactionType.income ? kSleekIncome : kSleekAccent;
    final title = tx.type == MoneyTransactionType.transfer
        ? '${account?.name ?? ''} → ${toAccount?.name ?? ''}'
        : tx.displayType == enumName(tx.type)
            ? category?.name ?? 'Unknown'
            : tx.displayType;
    return ExpressiveCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: tx.type == MoneyTransactionType.transfer
            ? iconBubble(context, 'exchange', '#38BDF8', size: 44)
            : iconBubble(context, category?.iconName ?? 'category', category?.iconColor ?? '#78D8E8', size: 44),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
        subtitle: Text(
          '${DateFormat('MMM d, yyyy • h:mm a').format(tx.createdOn)}${tx.notes.isEmpty ? '' : ' • ${tx.notes}'}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
        ),
        trailing: Text(
          '$amountPrefix${state.format(tx.amount)}',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900, color: amountColor),
        ),
        onTap: () => showTransactionEditor(context, transaction: tx),
      ),
    );
  }
}


Future<void> showTransactionEditor(BuildContext context, {MoneyTransaction? transaction, Category? lockedCategory}) async {
  await showKoinlyPopup<void>(
    context,
    maxWidth: 560,
    maxHeight: 700,
    child: TransactionEditor(transaction: transaction, lockedCategory: lockedCategory),
  );
}

class TransactionEditor extends StatefulWidget {
  const TransactionEditor({super.key, this.transaction, this.lockedCategory});
  final MoneyTransaction? transaction;
  final Category? lockedCategory;

  @override
  State<TransactionEditor> createState() => _TransactionEditorState();
}

class _TransactionEditorState extends State<TransactionEditor> {
  final notes = TextEditingController();
  final amount = TextEditingController(text: '0');
  MoneyTransactionType type = MoneyTransactionType.expense;
  String? categoryId;
  String? fromAccountId;
  String? toAccountId;
  DateTime selectedDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    final state = context.read<AppController>();
    final tx = widget.transaction;
    if (tx != null) {
      notes.text = tx.notes;
      amount.text = tx.amount.toStringAsFixed(2);
      type = tx.type;
      categoryId = tx.categoryId;
      fromAccountId = tx.fromAccountId;
      toAccountId = tx.toAccountId;
      selectedDate = tx.createdOn;
    } else {
      type = widget.lockedCategory?.type == CategoryType.income ? MoneyTransactionType.income : MoneyTransactionType.expense;
      categoryId = widget.lockedCategory?.id ?? (type == MoneyTransactionType.income ? state.defaultIncomeCategoryId : state.defaultExpenseCategoryId);
      fromAccountId = state.defaultAccountId ?? state.operatingAccounts.firstOrNull?.id;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final regularAccountOptions = state.operatingAccounts.isEmpty ? state.accounts : state.operatingAccounts;
    final transferFromOptions = state.accounts.where((a) => a.id != toAccountId).toList();
    final transferToOptions = state.accounts.where((a) => a.id != fromAccountId).toList();
    final accountOptions = type == MoneyTransactionType.transfer ? state.accounts : regularAccountOptions;
    final fromAccount = state.accounts.where((a) => a.id == fromAccountId).firstOrNull;
    final toAccount = state.accounts.where((a) => a.id == toAccountId).firstOrNull;
    final relevantCategories = state.categories.where((c) => c.type == (type == MoneyTransactionType.income ? CategoryType.income : CategoryType.expense) && !c.isLoanSystemCategory).toList();
    if (type == MoneyTransactionType.transfer) categoryId = '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 14),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.transaction == null ? 'Add transaction' : 'Edit transaction', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 12),
            SleekPillSelector<MoneyTransactionType>(
              options: const [
                SleekPillOption(value: MoneyTransactionType.expense, label: 'Expense', icon: Icons.north_east_rounded),
                SleekPillOption(value: MoneyTransactionType.income, label: 'Income', icon: Icons.south_west_rounded),
                SleekPillOption(value: MoneyTransactionType.transfer, label: 'Transfer', icon: Icons.swap_horiz_rounded),
              ],
              selected: type,
              onChanged: (v) => setState(() {
                type = v;
                if (type == MoneyTransactionType.income || type == MoneyTransactionType.expense) {
                  final targetType = type == MoneyTransactionType.income ? CategoryType.income : CategoryType.expense;
                  final newCategories = state.categories.where((c) => c.type == targetType && !c.isLoanSystemCategory).toList();
                  categoryId = type == MoneyTransactionType.income
                      ? state.defaultIncomeCategoryId ?? newCategories.firstOrNull?.id
                      : state.defaultExpenseCategoryId ?? newCategories.firstOrNull?.id;
                  final regularOptions = state.operatingAccounts.isEmpty ? state.accounts : state.operatingAccounts;
                  if (fromAccountId == null || regularOptions.where((a) => a.id == fromAccountId).firstOrNull == null) {
                    fromAccountId = state.defaultAccountId ?? regularOptions.firstOrNull?.id;
                  }
                  toAccountId = null;
                } else {
                  categoryId = '';
                  fromAccountId = fromAccountId ?? state.accounts.firstOrNull?.id;
                  if (toAccountId == fromAccountId) toAccountId = null;
                }
              }),
            ),
            const SizedBox(height: 12),
            AmountPadField(controller: amount),
            const SizedBox(height: 12),
            if (type != MoneyTransactionType.transfer && widget.lockedCategory == null)
              AppleSelectionField(
                label: 'Category',
                option: relevantCategories.where((c) => c.id == categoryId).firstOrNull == null ? null : optionFromCategory(relevantCategories.where((c) => c.id == categoryId).first),
                emptyText: 'Choose category',
                onTap: () async {
                  final selected = await showAppleWheelSelectionSheet(
                    context,
                    title: 'Choose Category',
                    selectedId: categoryId,
                    options: relevantCategories.map(optionFromCategory).toList(),
                  );
                  if (selected != null) setState(() => categoryId = selected);
                },
              ),
            if (widget.lockedCategory != null)
              ExpressiveCard(padding: const EdgeInsets.all(12), child: Row(children: [iconBubble(context, widget.lockedCategory!.iconName, widget.lockedCategory!.iconColor), const SizedBox(width: 12), Expanded(child: Text(widget.lockedCategory!.name, style: const TextStyle(fontWeight: FontWeight.w800)))])),
            const SizedBox(height: 12),
            AppleSelectionField(
              label: type == MoneyTransactionType.transfer ? 'From account' : 'Account',
              option: fromAccount == null ? null : optionFromAccount(fromAccount, state),
              emptyText: 'Choose account',
              onTap: () async {
                final selected = await showAppleWheelSelectionSheet(
                  context,
                  title: type == MoneyTransactionType.transfer ? 'Choose From Account' : 'Choose Account',
                  selectedId: fromAccountId,
                  options: (type == MoneyTransactionType.transfer ? transferFromOptions : accountOptions).map((a) => optionFromAccount(a, state)).toList(),
                );
                if (selected != null) {
                  setState(() {
                    fromAccountId = selected;
                    if (toAccountId == selected) toAccountId = null;
                  });
                }
              },
            ),
            if (type == MoneyTransactionType.transfer) ...[
              const SizedBox(height: 12),
              AppleSelectionField(
                label: 'To account',
                option: toAccount == null ? null : optionFromAccount(toAccount, state),
                emptyText: 'Choose destination account',
                onTap: () async {
                  final selected = await showAppleWheelSelectionSheet(
                    context,
                    title: 'Choose To Account',
                    selectedId: toAccountId,
                    options: transferToOptions.map((a) => optionFromAccount(a, state)).toList(),
                  );
                  if (selected != null) {
                    setState(() {
                      toAccountId = selected;
                      if (fromAccountId == selected) fromAccountId = null;
                    });
                  }
                },
              ),
            ],
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: OutlinedButton.icon(onPressed: () async { final d = await pickDate(context, selectedDate); if (d != null) setState(() => selectedDate = DateTime(d.year, d.month, d.day, selectedDate.hour, selectedDate.minute)); }, icon: const Icon(Icons.date_range_rounded), label: Text(DateFormat('MMM d, yyyy').format(selectedDate)))),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton.icon(onPressed: () async { final t = await pickTime(context, TimeOfDay.fromDateTime(selectedDate)); if (t != null) setState(() => selectedDate = DateTime(selectedDate.year, selectedDate.month, selectedDate.day, t.hour, t.minute)); }, icon: const Icon(Icons.schedule_rounded), label: Text(DateFormat('h:mm a').format(selectedDate)))),
            ]),
            const SizedBox(height: 12),
            TextField(controller: notes, minLines: 1, maxLines: 3, decoration: const InputDecoration(labelText: 'Notes')),
            const SizedBox(height: 18),
            Row(children: [
              if (widget.transaction != null) Expanded(child: OutlinedButton(onPressed: () async { await state.deleteTransaction(widget.transaction!.id); if (context.mounted) Navigator.pop(context); }, child: const Text('Delete'))),
              if (widget.transaction != null) const SizedBox(width: 12),
              Expanded(flex: 2, child: FilledButton(onPressed: () async {
                final value = double.tryParse(amount.text) ?? 0;
                if (value <= 0) return showSnack(context, 'Enter a valid amount');
                if (fromAccountId == null) return showSnack(context, 'Select an account');
                if (type == MoneyTransactionType.transfer && (toAccountId == null || toAccountId == fromAccountId)) return showSnack(context, 'Select a different destination account');
                if (type != MoneyTransactionType.transfer && categoryId == null) return showSnack(context, 'Select a category');
                final tx = MoneyTransaction(
                  id: widget.transaction?.id ?? _uuid.v4(),
                  type: type,
                  amount: value,
                  notes: notes.text.trim(),
                  categoryId: type == MoneyTransactionType.transfer ? '' : (categoryId ?? ''),
                  fromAccountId: fromAccountId!,
                  toAccountId: type == MoneyTransactionType.transfer ? toAccountId : null,
                  loanId: widget.transaction?.loanId,
                  repaymentId: widget.transaction?.repaymentId,
                  createdOn: selectedDate,
                  updatedOn: DateTime.now(),
                );
                if (widget.transaction == null) {
                  await state.addTransaction(tx);
                } else {
                  await state.updateTransaction(tx);
                }
                if (context.mounted) Navigator.pop(context);
              }, child: const Text('Save'))),
            ]),
          ],
        ),
      ),
    );
  }
}

class AmountPadField extends StatefulWidget {
  const AmountPadField({super.key, required this.controller});
  final TextEditingController controller;

  @override
  State<AmountPadField> createState() => _AmountPadFieldState();
}

class _AmountPadFieldState extends State<AmountPadField> {
  void input(String v) {
    var text = widget.controller.text;
    if (v == '⌫') {
      text = text.length <= 1 ? '0' : text.substring(0, text.length - 1);
    } else if (v == 'C') {
      text = '0';
    } else if (v == '.') {
      if (!text.contains('.')) text += '.';
    } else {
      text = text == '0' ? v : text + v;
    }
    setState(() => widget.controller.text = text);
  }

  @override
  Widget build(BuildContext context) {
    final keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', 'C', '0', '.', '⌫'];
    return ExpressiveCard(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: widget.controller,
            readOnly: true,
            showCursor: false,
            enableInteractiveSelection: false,
            keyboardType: TextInputType.none,
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900),
            decoration: const InputDecoration(prefixIcon: Icon(Icons.calculate_rounded), labelText: 'Amount'),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              const spacing = 8.0;
              final buttonWidth = (constraints.maxWidth - spacing * 2) / 3;
              final buttonHeight = (buttonWidth * 0.36).clamp(46.0, 58.0).toDouble();
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: keys
                    .map((k) => SizedBox(
                          width: buttonWidth,
                          height: buttonHeight,
                          child: _AmountPadButton(
                            label: k,
                            onPressed: () => input(k),
                          ),
                        ))
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AmountPadButton extends StatelessWidget {
  const _AmountPadButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isAction = label == 'C' || label == '⌫';
    return Material(
      color: isAction ? scheme.secondaryContainer : scheme.primaryContainer,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              textScaler: TextScaler.noScaling,
              textHeightBehavior: const TextHeightBehavior(applyHeightToFirstAscent: false, applyHeightToLastDescent: false),
              style: TextStyle(
                color: isAction ? scheme.onSecondaryContainer : scheme.onPrimaryContainer,
                fontSize: 23,
                height: 1,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showDateRangeSheet(BuildContext context) async {
  final state = context.read<AppController>();
  final selectedId = await showAppleWheelSelectionSheet(
    context,
    title: 'Choose Date Filter',
    selectedId: enumName(state.dateRangeType),
    options: DateRangeType.values.map(optionFromDateRangeType).toList(),
  );
  if (selectedId == null) return;
  final selected = DateRangeType.values.firstWhere(
    (type) => enumName(type) == selectedId,
    orElse: () => state.dateRangeType,
  );

  if (selected == DateRangeType.custom) {
    final start = await pickDate(context, state.customStart ?? DateTime.now());
    if (!context.mounted || start == null) return;
    final end = await pickDate(context, state.customEnd ?? start);
    await state.setDateRange(selected, start: start, end: end ?? start);
    return;
  }

  await state.setDateRange(selected);
}

SelectionOption optionFromDateRangeType(DateRangeType type) {
  switch (type) {
    case DateRangeType.today:
      return const SelectionOption(
        id: 'today',
        title: 'Today',
        subtitle: 'Only today',
        iconName: 'today',
        iconColor: '#78D8E8',
      );
    case DateRangeType.thisWeek:
      return const SelectionOption(
        id: 'thisWeek',
        title: 'This Week',
        subtitle: 'Current week',
        iconName: 'week',
        iconColor: '#A6E3A1',
      );
    case DateRangeType.thisMonth:
      return const SelectionOption(
        id: 'thisMonth',
        title: 'This Month',
        subtitle: 'Current month',
        iconName: 'month',
        iconColor: '#78D8E8',
      );
    case DateRangeType.thisYear:
      return const SelectionOption(
        id: 'thisYear',
        title: 'This Year',
        subtitle: 'Current year',
        iconName: 'year',
        iconColor: '#FBC879',
      );
    case DateRangeType.allTime:
      return const SelectionOption(
        id: 'allTime',
        title: 'All Time',
        subtitle: 'Everything saved',
        iconName: 'all_time',
        iconColor: '#B4A5FF',
      );
    case DateRangeType.custom:
      return const SelectionOption(
        id: 'custom',
        title: 'Custom',
        subtitle: 'Choose start and end date',
        iconName: 'custom_range',
        iconColor: '#FFB5D0',
      );
  }
}

Future<void> showFilterSheet(BuildContext context) async {
  await showKoinlyPopup<void>(
    context,
    maxWidth: 560,
    maxHeight: 700,
    child: const FilterSheet(),
  );
}

class FilterSheet extends StatefulWidget {
  const FilterSheet({super.key});

  @override
  State<FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<FilterSheet> {
  late List<String> accounts;
  late List<String> categories;
  late List<MoneyTransactionType> types;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppController>();
    accounts = List.of(state.filterAccountIds);
    categories = List.of(state.filterCategoryIds);
    types = List.of(state.filterTypes);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 14),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Filters', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
            const SectionHeader('Accounts'),
            Wrap(spacing: 8, runSpacing: 8, children: state.accounts.map((a) => FilterChip(label: Text(a.name), selected: accounts.contains(a.id), onSelected: (v) => setState(() => v ? accounts.add(a.id) : accounts.remove(a.id)))).toList()),
            const SectionHeader('Categories'),
            Wrap(spacing: 8, runSpacing: 8, children: state.categories.map((c) => FilterChip(label: Text(c.name), selected: categories.contains(c.id), onSelected: (v) => setState(() => v ? categories.add(c.id) : categories.remove(c.id)))).toList()),
            const SectionHeader('Types'),
            Wrap(spacing: 8, runSpacing: 8, children: MoneyTransactionType.values.map((t) => FilterChip(label: Text(enumName(t)), selected: types.contains(t), onSelected: (v) => setState(() => v ? types.add(t) : types.remove(t)))).toList()),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: () async { await state.clearFilters(); if (context.mounted) Navigator.pop(context); }, child: const Text('Clear'))),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: FilledButton(onPressed: () async { await state.saveFilters(accounts: accounts, categories: categories, types: types); if (context.mounted) Navigator.pop(context); }, child: const Text('Apply'))),
            ]),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Analysis and category breakdown
// -----------------------------------------------------------------------------

class AnalysisScreen extends StatefulWidget {
  const AnalysisScreen({super.key});

  @override
  State<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends State<AnalysisScreen> {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final range = state.activeRange();
    final txs = state.filteredTransactions();
    final summary = state.summaryFor(txs);
    final fallbackToday = DateTime.now();
    final fallbackDay = DateTime(fallbackToday.year, fallbackToday.month, fallbackToday.day);
    DateTime chartStart;
    DateTime chartEnd;
    if (range.start != null && range.end != null) {
      chartStart = range.start!;
      chartEnd = range.end!;
    } else if (txs.isNotEmpty) {
      final sortedDates = txs.map((tx) => tx.createdOn).toList()..sort();
      final first = sortedDates.first;
      final last = sortedDates.last;
      chartStart = DateTime(first.year, first.month, first.day);
      chartEnd = DateTime(last.year, last.month, last.day).add(const Duration(days: 1));
    } else {
      chartStart = fallbackDay;
      chartEnd = fallbackDay.add(const Duration(days: 1));
    }
    final daily = <DateTime, Summary>{};
    for (final tx in txs) {
      if (!tx.countsAsIncome && !tx.countsAsExpense) continue;
      final day = DateTime(tx.createdOn.year, tx.createdOn.month, tx.createdOn.day);
      final old = daily[day] ?? const Summary(income: 0, expense: 0);
      daily[day] = Summary(
        income: old.income + (tx.countsAsIncome ? tx.amount : 0),
        expense: old.expense + (tx.countsAsExpense ? tx.amount : 0),
      );
    }

    final totalDays = chartEnd.difference(chartStart).inDays;
    List<DateTime> days;
    if (totalDays > 0 && totalDays <= 62) {
      days = List.generate(totalDays, (index) => DateTime(chartStart.year, chartStart.month, chartStart.day).add(Duration(days: index)));
    } else if (daily.isNotEmpty) {
      days = daily.keys.toList()..sort();
    } else {
      days = [DateTime(chartStart.year, chartStart.month, chartStart.day)];
    }
    for (final day in days) {
      daily.putIfAbsent(day, () => const Summary(income: 0, expense: 0));
    }
    final avgDivisor = math.max(1, days.length);

    return PageScaffold(
      title: 'Analysis',
      subtitle: range.label,
      actions: [IconButton(onPressed: () => showFilterSheet(context), icon: const Icon(Icons.filter_alt_rounded))],
      child: ResponsiveContent(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(child: MiniMetric('Income', state.format(summary.income), Icons.south_west_rounded)),
              const SizedBox(width: 10),
              Expanded(child: MiniMetric('Expense', state.format(summary.expense), Icons.north_east_rounded)),
            ]),
            const SizedBox(height: 10),
            MiniMetric('Balance', state.format(summary.balance), Icons.account_balance_wallet_rounded),
            const SectionHeader('Trend'),
            RepaintBoundary(child: AnalysisTrendChart(days: days, daily: daily, rangeLabel: range.label)),
            const SectionHeader('Averages'),
            Row(children: [
              Expanded(child: MiniMetric('Income / day', state.format(summary.income / avgDivisor), Icons.trending_up_rounded)),
              const SizedBox(width: 10),
              Expanded(child: MiniMetric('Expense / day', state.format(summary.expense / avgDivisor), Icons.trending_down_rounded)),
            ]),
          ],
        ),
      ),
    );
  }
}

DateTime financialPeriodStart(FinancialHealthPeriod period, DateTime selectedDate) {
  return period == FinancialHealthPeriod.monthly ? DateTime(selectedDate.year, selectedDate.month, 1) : DateTime(selectedDate.year, 1, 1);
}

DateTime financialPeriodEnd(FinancialHealthPeriod period, DateTime selectedDate) {
  return period == FinancialHealthPeriod.monthly ? DateTime(selectedDate.year, selectedDate.month + 1, 1) : DateTime(selectedDate.year + 1, 1, 1);
}

String financialPeriodLabel(FinancialHealthPeriod period, DateTime selectedDate) {
  return period == FinancialHealthPeriod.monthly ? DateFormat('MMMM yyyy').format(selectedDate) : selectedDate.year.toString();
}

List<SelectionOption> financialMonthOptions() {
  final now = DateTime.now();
  return List.generate(144, (index) {
    final month = DateTime(now.year, now.month - index, 1);
    return SelectionOption(
      id: DateFormat('yyyy-MM').format(month),
      title: DateFormat('MMMM yyyy').format(month),
      subtitle: index == 0 ? 'Current month' : 'Monthly health summary',
      iconName: 'month',
      iconColor: '#78D8E8',
    );
  });
}

List<SelectionOption> financialYearOptions() {
  final now = DateTime.now();
  final count = math.max(1, now.year - 1999);
  return List.generate(count, (index) {
    final year = now.year - index;
    return SelectionOption(
      id: year.toString(),
      title: year.toString(),
      subtitle: index == 0 ? 'Current year' : 'Yearly health summary',
      iconName: 'year',
      iconColor: '#FBC879',
    );
  });
}

bool isInsideFinancialPeriod(DateTime date, DateTime start, DateTime end) => !date.isBefore(start) && date.isBefore(end);

List<MoneyTransaction> transactionsForFinancialPeriod(AppController state, DateTime start, DateTime end) {
  return state.transactions.where((tx) => isInsideFinancialPeriod(tx.createdOn, start, end)).toList();
}

bool transactionTouchesSavings(AppController state, MoneyTransaction tx) {
  final from = state.accountOf(tx.fromAccountId);
  final to = tx.toAccountId == null ? null : state.accountOf(tx.toAccountId!);
  return from?.type == AccountType.savings || to?.type == AccountType.savings;
}

bool isSavingsTransferIn(AppController state, MoneyTransaction tx) {
  if (tx.type != MoneyTransactionType.transfer) return false;
  final from = state.accountOf(tx.fromAccountId);
  final to = tx.toAccountId == null ? null : state.accountOf(tx.toAccountId!);
  return from?.type != AccountType.savings && to?.type == AccountType.savings;
}

bool isSavingsTransferOut(AppController state, MoneyTransaction tx) {
  if (tx.type != MoneyTransactionType.transfer) return false;
  final from = state.accountOf(tx.fromAccountId);
  final to = tx.toAccountId == null ? null : state.accountOf(tx.toAccountId!);
  return from?.type == AccountType.savings && to?.type != AccountType.savings;
}

bool isRecurringPaymentTransaction(AppController state, MoneyTransaction tx) {
  if (!tx.countsAsExpense) return false;
  final category = state.categoryOf(tx.categoryId)?.name.toLowerCase() ?? '';
  final notes = tx.notes.toLowerCase();
  final text = '$category $notes';
  const keywords = [
    'bill',
    'subscription',
    'tuition',
    'rent',
    'internet',
    'mobile recharge',
    'recharge',
    'electricity',
    'emi',
    'utility',
    'school fee',
    'fee',
    'netflix',
    'spotify',
    'youtube',
    'installment',
  ];
  return keywords.any(text.contains);
}

class BudgetThresholdCounts {
  const BudgetThresholdCounts({required this.safe, required this.fifty, required this.eighty, required this.full, required this.over});

  final int safe;
  final int fifty;
  final int eighty;
  final int full;
  final int over;
}

class BudgetHealthItem {
  const BudgetHealthItem({required this.label, required this.month, required this.limit, required this.spent});

  final String label;
  final DateTime month;
  final double limit;
  final double spent;

  double get remaining => limit - spent;
  double get overspent => math.max(0, spent - limit);
  double get ratio => limit <= 0 ? 0 : spent / limit;
  double get percentUsed => ratio * 100;
  bool get isOverspent => spent > limit && limit > 0;

  String get statusLabel {
    if (ratio >= 1.0001) return 'Over Budget';
    if (ratio >= .999) return 'Fully Used';
    if (ratio >= .8) return 'Near Limit';
    if (ratio >= .5) return '50% Used';
    return 'Safe';
  }
}

class MonthlyFinancialBreakdown {
  const MonthlyFinancialBreakdown({
    required this.month,
    required this.income,
    required this.expense,
    required this.savingsIn,
    required this.savingsOut,
    required this.loansGiven,
    required this.loansTaken,
    required this.loanRepaymentPaid,
    required this.loanRepaymentReceived,
    required this.billPaymentTotal,
    required this.billPaymentCount,
    required this.budgetLimit,
    required this.budgetSpent,
  });

  final DateTime month;
  final double income;
  final double expense;
  final double savingsIn;
  final double savingsOut;
  final double loansGiven;
  final double loansTaken;
  final double loanRepaymentPaid;
  final double loanRepaymentReceived;
  final double billPaymentTotal;
  final int billPaymentCount;
  final double budgetLimit;
  final double budgetSpent;

  double get cashFlow => income - expense;
  double get savingsNet => savingsIn - savingsOut;
  double get budgetRemaining => budgetLimit - budgetSpent;
  double get overspent => math.max(0, budgetSpent - budgetLimit);
}

class FinancialHealthSummary {
  const FinancialHealthSummary({
    required this.state,
    required this.period,
    required this.selectedDate,
    required this.start,
    required this.end,
    required this.periodLabel,
    required this.income,
    required this.expense,
    required this.savingsIn,
    required this.savingsOut,
    required this.currentSavingsBalance,
    required this.loansGiven,
    required this.loansTaken,
    required this.loanRepaymentPaid,
    required this.loanRepaymentReceived,
    required this.billPaymentTotal,
    required this.billPaymentCount,
    required this.billUnpaidCount,
    required this.billUpcomingCount,
    required this.billOverdueCount,
    required this.loanReminderCompletedCount,
    required this.loanReminderPendingCount,
    required this.loanReminderPartialCount,
    required this.loanReminderOverdueCount,
    required this.budgetItems,
    required this.budgetCounts,
    required this.monthlyBreakdowns,
    required this.status,
    required this.statusBody,
  });

  final AppController state;
  final FinancialHealthPeriod period;
  final DateTime selectedDate;
  final DateTime start;
  final DateTime end;
  final String periodLabel;
  final double income;
  final double expense;
  final double savingsIn;
  final double savingsOut;
  final double currentSavingsBalance;
  final double loansGiven;
  final double loansTaken;
  final double loanRepaymentPaid;
  final double loanRepaymentReceived;
  final double billPaymentTotal;
  final int billPaymentCount;
  final int billUnpaidCount;
  final int billUpcomingCount;
  final int billOverdueCount;
  final int loanReminderCompletedCount;
  final int loanReminderPendingCount;
  final int loanReminderPartialCount;
  final int loanReminderOverdueCount;
  final List<BudgetHealthItem> budgetItems;
  final BudgetThresholdCounts budgetCounts;
  final List<MonthlyFinancialBreakdown> monthlyBreakdowns;
  final String status;
  final String statusBody;

  double get cashFlow => income - expense;
  double get savingsNet => savingsIn - savingsOut;
  double get budgetLimit => budgetItems.fold<double>(0, (sum, item) => sum + item.limit);
  double get budgetSpent => budgetItems.fold<double>(0, (sum, item) => sum + item.spent);
  double get budgetRemaining => budgetLimit - budgetSpent;
  double get overspentTotal => budgetItems.fold<double>(0, (sum, item) => sum + item.overspent);
  List<BudgetHealthItem> get overspentItems => budgetItems.where((item) => item.isOverspent).toList();

  static FinancialHealthSummary build(AppController state, {required FinancialHealthPeriod period, required DateTime selectedDate}) {
    final start = financialPeriodStart(period, selectedDate);
    final end = financialPeriodEnd(period, selectedDate);
    final txs = transactionsForFinancialPeriod(state, start, end);
    double income = 0;
    double expense = 0;
    double savingsIn = 0;
    double savingsOut = 0;
    double loansGiven = 0;
    double loansTaken = 0;
    double loanRepaymentPaid = 0;
    double loanRepaymentReceived = 0;
    double billPaymentTotal = 0;
    var billPaymentCount = 0;

    for (final tx in txs) {
      if (tx.countsAsIncome) income += tx.amount;
      if (tx.countsAsExpense) expense += tx.amount;
      if (isSavingsTransferIn(state, tx)) savingsIn += tx.amount;
      if (isSavingsTransferOut(state, tx)) savingsOut += tx.amount;
      if (tx.isLoanPrincipal) {
        if (tx.type == MoneyTransactionType.expense) loansGiven += tx.amount;
        if (tx.type == MoneyTransactionType.income) loansTaken += tx.amount;
      }
      if (tx.isLoanRepayment) {
        if (tx.type == MoneyTransactionType.expense) loanRepaymentPaid += tx.amount;
        if (tx.type == MoneyTransactionType.income) loanRepaymentReceived += tx.amount;
      }
      if (isRecurringPaymentTransaction(state, tx)) {
        billPaymentTotal += tx.amount;
        billPaymentCount++;
      }
    }

    var loanReminderCompleted = 0;
    var loanReminderPending = 0;
    var loanReminderPartial = 0;
    var loanReminderOverdue = 0;
    for (final reminder in state.loanRepaymentReminders) {
      final paidInPeriod = reminder.isPaid && reminder.paidOn != null && isInsideFinancialPeriod(reminder.paidOn!, start, end);
      final dueInPeriod = isInsideFinancialPeriod(reminder.dueDate, start, end);
      if (!paidInPeriod && !dueInPeriod) continue;
      final loan = state.loanOf(reminder.loanId);
      if (paidInPeriod) loanReminderCompleted++;
      if (!reminder.isPaid && reminder.isOverdue) {
        loanReminderOverdue++;
      } else if (!reminder.isPaid) {
        loanReminderPending++;
      }
      if (loan != null && loan.repaidAmount > 0 && loan.remainingAmount > 0) loanReminderPartial++;
    }

    final budgetItems = budgetHealthItemsForPeriod(state, period, selectedDate);
    var safe = 0;
    var fifty = 0;
    var eighty = 0;
    var full = 0;
    var over = 0;
    for (final item in budgetItems) {
      if (item.ratio >= 1.0001) {
        over++;
      } else if (item.ratio >= .999) {
        full++;
      } else if (item.ratio >= .8) {
        eighty++;
      } else if (item.ratio >= .5) {
        fifty++;
      } else {
        safe++;
      }
    }

    final monthlyBreakdowns = period == FinancialHealthPeriod.yearly
        ? List.generate(12, (index) => monthlyBreakdownFor(state, DateTime(selectedDate.year, index + 1, 1)))
        : <MonthlyFinancialBreakdown>[];

    final statusInfo = financialHealthStatus(
      period: period,
      income: income,
      expense: expense,
      savingsNet: savingsIn - savingsOut,
      loansTaken: loansTaken,
      loanRepaymentPaid: loanRepaymentPaid,
      overspentTotal: budgetItems.fold<double>(0, (sum, item) => sum + item.overspent),
    );

    return FinancialHealthSummary(
      state: state,
      period: period,
      selectedDate: selectedDate,
      start: start,
      end: end,
      periodLabel: financialPeriodLabel(period, selectedDate),
      income: income,
      expense: expense,
      savingsIn: savingsIn,
      savingsOut: savingsOut,
      currentSavingsBalance: state.savingAccountBalance,
      loansGiven: loansGiven,
      loansTaken: loansTaken,
      loanRepaymentPaid: loanRepaymentPaid,
      loanRepaymentReceived: loanRepaymentReceived,
      billPaymentTotal: billPaymentTotal,
      billPaymentCount: billPaymentCount,
      billUnpaidCount: 0,
      billUpcomingCount: 0,
      billOverdueCount: 0,
      loanReminderCompletedCount: loanReminderCompleted,
      loanReminderPendingCount: loanReminderPending,
      loanReminderPartialCount: loanReminderPartial,
      loanReminderOverdueCount: loanReminderOverdue,
      budgetItems: budgetItems,
      budgetCounts: BudgetThresholdCounts(safe: safe, fifty: fifty, eighty: eighty, full: full, over: over),
      monthlyBreakdowns: monthlyBreakdowns,
      status: statusInfo.$1,
      statusBody: statusInfo.$2,
    );
  }
}

(String, String) financialHealthStatus({
  required FinancialHealthPeriod period,
  required double income,
  required double expense,
  required double savingsNet,
  required double loansTaken,
  required double loanRepaymentPaid,
  required double overspentTotal,
}) {
  final label = period == FinancialHealthPeriod.monthly ? 'month' : 'year';
  if (loansTaken > loanRepaymentPaid && loansTaken > 0) {
    return ('Increased Debt', 'Borrowed amount was higher than debt repayment in this $label.');
  }
  if (loanRepaymentPaid > loansTaken && loanRepaymentPaid > 0) {
    return ('Reduced Debt', 'Debt repayment was higher than new borrowing in this $label.');
  }
  if (overspentTotal > 0 || expense > income) {
    return ('Overspent', 'Expenses or budget usage were higher than the safe limit in this $label.');
  }
  if (savingsNet > math.max(100, income * .18)) {
    return ('Strong Savings Growth', 'Savings transfers were strong compared with income in this $label.');
  }
  if (income > expense) {
    return ('Saved Money', 'Income stayed above expenses in this $label.');
  }
  return ('Stable ${period == FinancialHealthPeriod.monthly ? 'Month' : 'Year'}', 'Money flow stayed close to neutral in this $label.');
}

List<BudgetHealthItem> budgetHealthItemsForPeriod(AppController state, FinancialHealthPeriod period, DateTime selectedDate) {
  final items = <BudgetHealthItem>[];
  for (final budget in state.budgets) {
    final month = DateTime(budget.selectedMonth.year, budget.selectedMonth.month, 1);
    if (period == FinancialHealthPeriod.monthly) {
      if (month.year != selectedDate.year || month.month != selectedDate.month) continue;
    } else if (month.year != selectedDate.year) {
      continue;
    }
    final start = DateTime(month.year, month.month, 1);
    final end = DateTime(month.year, month.month + 1, 1);
    final txs = state.transactions.where((tx) {
      if (!tx.countsAsExpense) return false;
      if (!isInsideFinancialPeriod(tx.createdOn, start, end)) return false;
      if (!budget.allAccountsSelected && !budget.accountIds.contains(tx.fromAccountId)) return false;
      if (!budget.allCategoriesSelected && !budget.categoryIds.contains(tx.categoryId)) return false;
      return true;
    }).toList();
    final spent = txs.fold<double>(0, (sum, tx) => sum + tx.amount);
    final categoryNames = budget.allCategoriesSelected
        ? 'All expense categories'
        : budget.categoryIds.map((id) => state.categoryOf(id)?.name ?? 'Category').take(3).join(', ');
    final accountNames = budget.allAccountsSelected ? 'all accounts' : budget.accountIds.map((id) => state.accountOf(id)?.name ?? 'Account').take(2).join(', ');
    final label = period == FinancialHealthPeriod.yearly ? '${DateFormat('MMM').format(month)} • $categoryNames' : '$categoryNames • $accountNames';
    items.add(BudgetHealthItem(label: label, month: month, limit: budget.amount, spent: spent));
  }
  return items;
}

MonthlyFinancialBreakdown monthlyBreakdownFor(AppController state, DateTime month) {
  final start = DateTime(month.year, month.month, 1);
  final end = DateTime(month.year, month.month + 1, 1);
  final txs = transactionsForFinancialPeriod(state, start, end);
  double income = 0;
  double expense = 0;
  double savingsIn = 0;
  double savingsOut = 0;
  double loansGiven = 0;
  double loansTaken = 0;
  double loanRepaymentPaid = 0;
  double loanRepaymentReceived = 0;
  double billPaymentTotal = 0;
  var billPaymentCount = 0;
  for (final tx in txs) {
    if (tx.countsAsIncome) income += tx.amount;
    if (tx.countsAsExpense) expense += tx.amount;
    if (isSavingsTransferIn(state, tx)) savingsIn += tx.amount;
    if (isSavingsTransferOut(state, tx)) savingsOut += tx.amount;
    if (tx.isLoanPrincipal) {
      if (tx.type == MoneyTransactionType.expense) loansGiven += tx.amount;
      if (tx.type == MoneyTransactionType.income) loansTaken += tx.amount;
    }
    if (tx.isLoanRepayment) {
      if (tx.type == MoneyTransactionType.expense) loanRepaymentPaid += tx.amount;
      if (tx.type == MoneyTransactionType.income) loanRepaymentReceived += tx.amount;
    }
    if (isRecurringPaymentTransaction(state, tx)) {
      billPaymentTotal += tx.amount;
      billPaymentCount++;
    }
  }
  final budgetItems = budgetHealthItemsForPeriod(state, FinancialHealthPeriod.monthly, month);
  return MonthlyFinancialBreakdown(
    month: month,
    income: income,
    expense: expense,
    savingsIn: savingsIn,
    savingsOut: savingsOut,
    loansGiven: loansGiven,
    loansTaken: loansTaken,
    loanRepaymentPaid: loanRepaymentPaid,
    loanRepaymentReceived: loanRepaymentReceived,
    billPaymentTotal: billPaymentTotal,
    billPaymentCount: billPaymentCount,
    budgetLimit: budgetItems.fold<double>(0, (sum, item) => sum + item.limit),
    budgetSpent: budgetItems.fold<double>(0, (sum, item) => sum + item.spent),
  );
}

class FinancialHealthPeriodCard extends StatelessWidget {
  const FinancialHealthPeriodCard({super.key, required this.period, required this.selectedDate, required this.onPeriodChanged, required this.onPickDate});

  final FinancialHealthPeriod period;
  final DateTime selectedDate;
  final ValueChanged<FinancialHealthPeriod> onPeriodChanged;
  final VoidCallback onPickDate;

  @override
  Widget build(BuildContext context) {
    final selectedLabel = financialPeriodLabel(period, selectedDate);
    return ExpressiveCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<FinancialHealthPeriod>(
            segments: const [
              ButtonSegment(value: FinancialHealthPeriod.monthly, label: Text('Monthly'), icon: Icon(Icons.calendar_month_rounded)),
              ButtonSegment(value: FinancialHealthPeriod.yearly, label: Text('Yearly'), icon: Icon(Icons.calendar_view_month_rounded)),
            ],
            selected: {period},
            onSelectionChanged: (value) => onPeriodChanged(value.first),
            showSelectedIcon: false,
          ),
          const SizedBox(height: 12),
          Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(.48),
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: onPickDate,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    iconBubble(context, period == FinancialHealthPeriod.monthly ? 'month' : 'year', period == FinancialHealthPeriod.monthly ? '#78D8E8' : '#FBC879', size: 42),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(selectedLabel, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
                          Text(period == FinancialHealthPeriod.monthly ? 'Tap to choose another month' : 'Tap to choose another year', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                    Icon(Icons.keyboard_arrow_down_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class FinancialHealthSummarySection extends StatelessWidget {
  const FinancialHealthSummarySection({super.key, required this.summary});

  final FinancialHealthSummary summary;

  @override
  Widget build(BuildContext context) {
    final state = summary.state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Financial Health Summary'),
        FinancialHealthStatusCard(summary: summary),
        const SizedBox(height: 10),
        HealthMetricWrap(metrics: [
          HealthMetricData('Money flow', state.format(summary.cashFlow), Icons.compare_arrows_rounded),
          HealthMetricData('Savings in', state.format(summary.savingsIn), Icons.savings_rounded),
          HealthMetricData('Savings out', state.format(summary.savingsOut), Icons.output_rounded),
          HealthMetricData('Savings change', state.format(summary.savingsNet), Icons.trending_up_rounded),
          HealthMetricData('Current savings', state.format(summary.currentSavingsBalance), Icons.account_balance_rounded),
          HealthMetricData('Loans given', state.format(summary.loansGiven), Icons.north_east_rounded),
          HealthMetricData('Loans taken', state.format(summary.loansTaken), Icons.south_west_rounded),
          HealthMetricData('Repayment paid', state.format(summary.loanRepaymentPaid), Icons.payments_rounded),
          HealthMetricData('Repayment received', state.format(summary.loanRepaymentReceived), Icons.call_received_rounded),
          HealthMetricData('Recurring paid', state.format(summary.billPaymentTotal), Icons.receipt_long_rounded),
          HealthMetricData('Budget remaining', state.format(summary.budgetRemaining), Icons.pie_chart_rounded),
          HealthMetricData('Overspent', state.format(summary.overspentTotal), Icons.warning_rounded),
        ]),
        const SizedBox(height: 10),
        FinancialHealthCharts(summary: summary),
        const SizedBox(height: 10),
        BudgetHealthCard(summary: summary),
        const SizedBox(height: 10),
        LoanAndBillStatusCard(summary: summary),
        if (summary.overspentItems.isNotEmpty) ...[
          const SizedBox(height: 10),
          OverspendingCategoriesCard(summary: summary),
        ],
        if (summary.period == FinancialHealthPeriod.yearly) ...[
          const SizedBox(height: 10),
          YearlyComparisonCard(summary: summary),
          const SizedBox(height: 10),
          YearlyBreakdownCard(summary: summary),
        ],
      ],
    );
  }
}

class FinancialHealthStatusCard extends StatelessWidget {
  const FinancialHealthStatusCard({super.key, required this.summary});

  final FinancialHealthSummary summary;

  Color _statusColor() {
    final lower = summary.status.toLowerCase();
    if (lower.contains('over') || lower.contains('debt')) return kSleekExpense;
    if (lower.contains('strong') || lower.contains('saved') || lower.contains('reduced')) return kSleekIncome;
    return kSleekAccent;
  }

  @override
  Widget build(BuildContext context) {
    final color = _statusColor();
    return ExpressiveCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(color: color.withOpacity(.15), borderRadius: BorderRadius.circular(18), border: Border.all(color: color.withOpacity(.30))),
            child: Icon(Icons.health_and_safety_rounded, color: color),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(summary.status, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900)),
                    HealthStatusPill(label: summary.periodLabel, color: color),
                    const HealthStatusPill(label: 'Savings transfers are internal', color: kSleekAccent),
                  ],
                ),
                const SizedBox(height: 6),
                Text(summary.statusBody, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class HealthStatusPill extends StatelessWidget {
  const HealthStatusPill({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: color.withOpacity(.12), borderRadius: BorderRadius.circular(999), border: Border.all(color: color.withOpacity(.24))),
      child: Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w900)),
    );
  }
}

class HealthMetricData {
  const HealthMetricData(this.label, this.value, this.icon);
  final String label;
  final String value;
  final IconData icon;
}

class HealthMetricWrap extends StatelessWidget {
  const HealthMetricWrap({super.key, required this.metrics});

  final List<HealthMetricData> metrics;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumns = constraints.maxWidth >= 680;
        final width = twoColumns ? (constraints.maxWidth - 10) / 2 : constraints.maxWidth;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: metrics.map((metric) => SizedBox(width: width, child: MiniMetric(metric.label, metric.value, metric.icon))).toList(),
        );
      },
    );
  }
}

class FinancialHealthCharts extends StatelessWidget {
  const FinancialHealthCharts({super.key, required this.summary});

  final FinancialHealthSummary summary;

  @override
  Widget build(BuildContext context) {
    final state = summary.state;
    final budgetRemaining = math.max(0.0, summary.budgetRemaining);
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumns = constraints.maxWidth >= 760;
        final width = twoColumns ? (constraints.maxWidth - 10) / 2 : constraints.maxWidth;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            SizedBox(
              width: width,
              child: HealthBarChartCard(
                title: 'Income vs Expense',
                icon: Icons.stacked_bar_chart_rounded,
                bars: [
                  HealthBarData('Income', summary.income, state.format(summary.income), kSleekIncome),
                  HealthBarData('Expense', summary.expense, state.format(summary.expense), kSleekExpense),
                ],
              ),
            ),
            SizedBox(
              width: width,
              child: HealthBarChartCard(
                title: 'Savings Growth',
                icon: Icons.savings_rounded,
                bars: [
                  HealthBarData('Transferred in', summary.savingsIn, state.format(summary.savingsIn), kSleekIncome),
                  HealthBarData('Transferred out', summary.savingsOut, state.format(summary.savingsOut), kSleekExpense),
                  HealthBarData('Net change', summary.savingsNet.abs(), state.format(summary.savingsNet), summary.savingsNet >= 0 ? kSleekIncome : kSleekExpense),
                ],
              ),
            ),
            SizedBox(
              width: width,
              child: HealthBarChartCard(
                title: 'Loan Activity',
                icon: Icons.account_balance_rounded,
                bars: [
                  HealthBarData('Given', summary.loansGiven, state.format(summary.loansGiven), const Color(0xFFFF9AA2)),
                  HealthBarData('Taken', summary.loansTaken, state.format(summary.loansTaken), const Color(0xFF8AB4FF)),
                  HealthBarData('Paid', summary.loanRepaymentPaid, state.format(summary.loanRepaymentPaid), kSleekExpense),
                  HealthBarData('Received', summary.loanRepaymentReceived, state.format(summary.loanRepaymentReceived), kSleekIncome),
                ],
              ),
            ),
            SizedBox(
              width: width,
              child: HealthBarChartCard(
                title: 'Budget Usage',
                icon: Icons.pie_chart_rounded,
                bars: [
                  HealthBarData('Used', summary.budgetSpent, state.format(summary.budgetSpent), kSleekWarning),
                  HealthBarData('Remaining', budgetRemaining, state.format(summary.budgetRemaining), kSleekIncome),
                  HealthBarData('Overspent', summary.overspentTotal, state.format(summary.overspentTotal), kSleekExpense),
                ],
              ),
            ),
            SizedBox(
              width: width,
              child: HealthBarChartCard(
                title: 'Recurring Payments',
                icon: Icons.repeat_rounded,
                bars: [
                  HealthBarData('Paid bills', summary.billPaymentTotal, state.format(summary.billPaymentTotal), kSleekAccent),
                  HealthBarData('Loan reminders', (summary.loanReminderPendingCount + summary.loanReminderOverdueCount).toDouble(), '${summary.loanReminderPendingCount + summary.loanReminderOverdueCount}', kSleekWarning),
                  HealthBarData('Overdue alerts', summary.loanReminderOverdueCount.toDouble(), '${summary.loanReminderOverdueCount}', kSleekExpense),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class HealthBarData {
  const HealthBarData(this.label, this.value, this.displayValue, this.color);
  final String label;
  final double value;
  final String displayValue;
  final Color color;
}

class HealthBarChartCard extends StatelessWidget {
  const HealthBarChartCard({super.key, required this.title, required this.icon, required this.bars});

  final String title;
  final IconData icon;
  final List<HealthBarData> bars;

  @override
  Widget build(BuildContext context) {
    final maxValue = bars.fold<double>(0, (max, bar) => math.max(max, bar.value.abs()));
    return ExpressiveCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: kSleekAccent),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900))),
            ],
          ),
          const SizedBox(height: 14),
          ...bars.map((bar) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: HealthBarRow(data: bar, maxValue: maxValue),
              )),
        ],
      ),
    );
  }
}

class HealthBarRow extends StatelessWidget {
  const HealthBarRow({super.key, required this.data, required this.maxValue});

  final HealthBarData data;
  final double maxValue;

  @override
  Widget build(BuildContext context) {
    final factor = maxValue <= 0 ? 0.0 : (data.value.abs() / maxValue).clamp(0.0, 1.0).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(data.label, style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800))),
            const SizedBox(width: 8),
            Text(data.displayValue, style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w900)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: Container(
            height: 10,
            color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(.58),
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: factor,
              child: Container(decoration: BoxDecoration(color: data.color, borderRadius: BorderRadius.circular(999))),
            ),
          ),
        ),
      ],
    );
  }
}

class BudgetHealthCard extends StatelessWidget {
  const BudgetHealthCard({super.key, required this.summary});

  final FinancialHealthSummary summary;

  @override
  Widget build(BuildContext context) {
    final state = summary.state;
    final counts = summary.budgetCounts;
    return ExpressiveCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Budget status', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              HealthStatusPill(label: 'Safe ${counts.safe}', color: kSleekIncome),
              HealthStatusPill(label: '50% ${counts.fifty}', color: kSleekAccent),
              HealthStatusPill(label: '80% ${counts.eighty}', color: kSleekWarning),
              HealthStatusPill(label: '100% ${counts.full}', color: const Color(0xFFFFB86B)),
              HealthStatusPill(label: 'Over ${counts.over}', color: kSleekExpense),
            ],
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: MiniMetric('Budget limit', state.format(summary.budgetLimit), Icons.flag_rounded)),
            const SizedBox(width: 10),
            Expanded(child: MiniMetric('Remaining budget', state.format(summary.budgetRemaining), Icons.savings_rounded)),
          ]),
        ],
      ),
    );
  }
}

class LoanAndBillStatusCard extends StatelessWidget {
  const LoanAndBillStatusCard({super.key, required this.summary});

  final FinancialHealthSummary summary;

  @override
  Widget build(BuildContext context) {
    return ExpressiveCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Reminders and scheduled payments', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              HealthStatusPill(label: 'Bills paid ${summary.billPaymentCount}', color: kSleekAccent),
              HealthStatusPill(label: 'Bills unpaid ${summary.billUnpaidCount}', color: kSleekWarning),
              HealthStatusPill(label: 'Bills upcoming ${summary.billUpcomingCount}', color: const Color(0xFF8AB4FF)),
              HealthStatusPill(label: 'Bills overdue ${summary.billOverdueCount}', color: kSleekExpense),
              HealthStatusPill(label: 'Loan completed ${summary.loanReminderCompletedCount}', color: kSleekIncome),
              HealthStatusPill(label: 'Loan pending ${summary.loanReminderPendingCount}', color: kSleekWarning),
              HealthStatusPill(label: 'Loan partial ${summary.loanReminderPartialCount}', color: kSleekAccent),
              HealthStatusPill(label: 'Loan overdue ${summary.loanReminderOverdueCount}', color: kSleekExpense),
            ],
          ),
        ],
      ),
    );
  }
}

class OverspendingCategoriesCard extends StatelessWidget {
  const OverspendingCategoriesCard({super.key, required this.summary});

  final FinancialHealthSummary summary;

  @override
  Widget build(BuildContext context) {
    final state = summary.state;
    return ExpressiveCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Overspending categories', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          ...summary.overspentItems.map((item) => Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: kSleekExpense.withOpacity(.08),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: kSleekExpense.withOpacity(.18)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(item.label, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900))),
                          Text('${item.percentUsed.toStringAsFixed(0)}%', style: Theme.of(context).textTheme.titleSmall?.copyWith(color: kSleekExpense, fontWeight: FontWeight.w900)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text('Spent ${state.format(item.spent)} • Limit ${state.format(item.limit)} • Overspent ${state.format(item.overspent)}', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              )),
        ],
      ),
    );
  }
}

class YearlyComparisonCard extends StatelessWidget {
  const YearlyComparisonCard({super.key, required this.summary});

  final FinancialHealthSummary summary;

  MonthlyFinancialBreakdown? _maxBy(double Function(MonthlyFinancialBreakdown item) selector) {
    if (summary.monthlyBreakdowns.isEmpty) return null;
    return summary.monthlyBreakdowns.reduce((a, b) => selector(a) >= selector(b) ? a : b);
  }

  MonthlyFinancialBreakdown? _minBy(double Function(MonthlyFinancialBreakdown item) selector) {
    if (summary.monthlyBreakdowns.isEmpty) return null;
    return summary.monthlyBreakdowns.reduce((a, b) => selector(a) <= selector(b) ? a : b);
  }

  String _month(MonthlyFinancialBreakdown? item) => item == null ? '-' : DateFormat('MMM').format(item.month);

  @override
  Widget build(BuildContext context) {
    final best = _maxBy((item) => item.cashFlow);
    final worst = _minBy((item) => item.cashFlow);
    final highestExpense = _maxBy((item) => item.expense);
    final highestIncome = _maxBy((item) => item.income);
    final highestSavings = _maxBy((item) => item.savingsNet);
    final mostOverspent = _maxBy((item) => item.overspent);
    return ExpressiveCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Monthly comparison', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              HealthStatusPill(label: 'Best ${_month(best)}', color: kSleekIncome),
              HealthStatusPill(label: 'Worst ${_month(worst)}', color: kSleekExpense),
              HealthStatusPill(label: 'Highest expense ${_month(highestExpense)}', color: kSleekWarning),
              HealthStatusPill(label: 'Highest income ${_month(highestIncome)}', color: kSleekIncome),
              HealthStatusPill(label: 'Highest savings ${_month(highestSavings)}', color: kSleekAccent),
              HealthStatusPill(label: 'Most overspent ${_month(mostOverspent)}', color: kSleekExpense),
            ],
          ),
        ],
      ),
    );
  }
}

class YearlyBreakdownCard extends StatelessWidget {
  const YearlyBreakdownCard({super.key, required this.summary});

  final FinancialHealthSummary summary;

  @override
  Widget build(BuildContext context) {
    final state = summary.state;
    final maxExpense = summary.monthlyBreakdowns.fold<double>(0, (max, item) => math.max(max, item.expense));
    return ExpressiveCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Yearly breakdown', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
          const SizedBox(height: 10),
          ...summary.monthlyBreakdowns.map((item) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: MonthBreakdownTile(item: item, maxExpense: maxExpense, state: state),
              )),
        ],
      ),
    );
  }
}

class MonthBreakdownTile extends StatelessWidget {
  const MonthBreakdownTile({super.key, required this.item, required this.maxExpense, required this.state});

  final MonthlyFinancialBreakdown item;
  final double maxExpense;
  final AppController state;

  @override
  Widget build(BuildContext context) {
    final factor = maxExpense <= 0 ? 0.0 : (item.expense / maxExpense).clamp(0.0, 1.0).toDouble();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(.42),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(width: 44, child: Text(DateFormat('MMM').format(item.month), style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900))),
              Expanded(child: Text('Income ${state.format(item.income)} • Expense ${state.format(item.expense)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700))),
              Text(state.format(item.cashFlow), style: Theme.of(context).textTheme.labelLarge?.copyWith(color: item.cashFlow >= 0 ? kSleekIncome : kSleekExpense, fontWeight: FontWeight.w900)),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: Container(
              height: 9,
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(.70),
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(widthFactor: factor, child: Container(color: kSleekExpense)),
            ),
          ),
          const SizedBox(height: 6),
          Text('Savings ${state.format(item.savingsNet)} • Loans ${state.format(item.loansGiven + item.loansTaken)} • Repayments ${state.format(item.loanRepaymentPaid + item.loanRepaymentReceived)} • Bills ${item.billPaymentCount} • Budget used ${state.format(item.budgetSpent)}', maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class AnalysisTrendChart extends StatelessWidget {
  const AnalysisTrendChart({
    super.key,
    required this.days,
    required this.daily,
    required this.rangeLabel,
  });

  final List<DateTime> days;
  final Map<DateTime, Summary> daily;
  final String rangeLabel;

  static const Color _chartCard = Color(0xFF242A35);
  static const Color _chartPanel = Color(0xFF222832);
  static const Color _incomeStart = Color(0xFFFF7A1A);
  static const Color _incomeEnd = Color(0xFFFF2E2E);
  static const Color _expenseStart = Color(0xFF8A2BFF);
  static const Color _expenseEnd = Color(0xFFFF6CAD);
  static const Color _axisText = Color(0xFFB7BEC9);
  static const Color _softGrid = Color(0xFF59616E);

  List<FlSpot> _spotsFor(bool income) {
    if (days.isEmpty) return const [FlSpot(0, 0), FlSpot(1, 0)];
    final result = <FlSpot>[];
    for (var i = 0; i < days.length; i++) {
      final summary = daily[days[i]] ?? const Summary(income: 0, expense: 0);
      result.add(FlSpot(i.toDouble(), income ? summary.income : summary.expense));
    }
    if (result.length == 1) result.add(FlSpot(1, result.first.y));
    return result;
  }

  ({double minY, double maxY}) _bounds(List<FlSpot> incomeSpots, List<FlSpot> expenseSpots) {
    final values = <double>[
      ...incomeSpots.map((spot) => spot.y),
      ...expenseSpots.map((spot) => spot.y),
    ];
    final high = values.fold<double>(0, (max, value) => math.max(max, value));
    if (high <= 0) return (minY: 0, maxY: 100);

    final padded = high * 1.22;
    final magnitude = math.pow(10, (math.log(padded) / math.ln10).floor()).toDouble();
    final normalized = padded / magnitude;
    final rounded = normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10;
    return (minY: 0, maxY: rounded * magnitude);
  }

  double _highlightX(List<FlSpot> incomeSpots, List<FlSpot> expenseSpots) {
    final length = math.min(incomeSpots.length, expenseSpots.length);
    for (var i = length - 1; i >= 0; i--) {
      if (incomeSpots[i].y != 0 || expenseSpots[i].y != 0) return incomeSpots[i].x;
    }
    return length <= 1 ? 0 : incomeSpots.last.x;
  }

  String _compactCurrency(AppController state, double value) {
    if (state.amountsHidden) {
      return state.currencyPosition == CurrencyPosition.prefix ? '${state.currencySymbol}••••' : '••••${state.currencySymbol}';
    }
    final absValue = value.abs();
    String number;
    if (absValue >= 1000000) {
      number = '${(absValue / 1000000).toStringAsFixed(absValue % 1000000 == 0 ? 0 : 1)}M';
    } else if (absValue >= 1000) {
      number = '${(absValue / 1000).toStringAsFixed(absValue % 1000 == 0 ? 0 : 1)}K';
    } else {
      number = absValue.toStringAsFixed(absValue % 1 == 0 ? 0 : 1);
    }

    final sign = value < 0 ? '-' : '';
    return state.currencyPosition == CurrencyPosition.prefix
        ? '$sign${state.currencySymbol}$number'
        : '$sign$number${state.currencySymbol}';
  }

  Widget _leftTitle(BuildContext context, double value, TitleMeta meta, double maxY, Color axisColor) {
    final interval = maxY / 4;
    if (interval <= 0) return const SizedBox.shrink();
    final roundedSlot = (value / interval).round();
    final expected = roundedSlot * interval;
    if ((value - expected).abs() > 0.01) return const SizedBox.shrink();
    final state = context.read<AppController>();
    return Text(
      _compactCurrency(state, value),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: axisColor.withOpacity(.72),
            fontWeight: FontWeight.w800,
          ),
    );
  }

  Widget _bottomTitle(BuildContext context, double value, TitleMeta meta, Color axisColor) {
    if (days.isEmpty) return const SizedBox.shrink();
    final indexes = <int>{
      0,
      if (days.length > 2) (days.length * .5).round(),
      days.length - 1,
    }.where((i) => i >= 0 && i < days.length).toList()
      ..sort();

    final index = value.round();
    if (!indexes.contains(index)) return const SizedBox.shrink();
    final day = days[index];
    final label = days.length > 45 ? DateFormat('MMM').format(day).toUpperCase() : DateFormat('MMM d').format(day);
    return SideTitleWidget(
      axisSide: meta.axisSide,
      space: 10,
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: axisColor.withOpacity(.78),
              fontWeight: FontWeight.w900,
              letterSpacing: .2,
            ),
      ),
    );
  }

  List<FlSpot> _animatedSpots(List<FlSpot> spots, double animation) {
    return spots.map((spot) => FlSpot(spot.x, spot.y * animation)).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final chartCardColor = isDark ? _chartCard : const Color(0xFFFBFEFF);
    final chartPanelColor = isDark ? _chartPanel : const Color(0xFFF7FCFD);
    final titleColor = isDark ? Colors.white : scheme.onSurface;
    final axisColor = isDark ? _axisText : scheme.onSurfaceVariant;
    final gridColor = isDark ? _softGrid : const Color(0xFFD8E6EA);
    final chartBorderColor = isDark ? Colors.white.withOpacity(.045) : const Color(0xFFDCEBEE);
    final panelShadowColor = isDark ? Colors.black.withOpacity(.22) : Colors.black.withOpacity(.045);
    final buttonBackground = isDark ? Colors.white.withOpacity(.08) : const Color(0xFFEAF3F5);
    final buttonForeground = isDark ? Colors.white : scheme.onSurface;
    final incomeSpots = _spotsFor(true);
    final expenseSpots = _spotsFor(false);
    final bounds = _bounds(incomeSpots, expenseSpots);
    final minY = bounds.minY;
    final maxY = bounds.maxY;
    final maxX = math.max(1.0, (days.length - 1).toDouble());
    final highlightX = _highlightX(incomeSpots, expenseSpots).clamp(0, maxX).toDouble();
    final hasData = incomeSpots.any((spot) => spot.y != 0) || expenseSpots.any((spot) => spot.y != 0);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 720),
      curve: Curves.easeOutCubic,
      builder: (context, animation, child) {
        final animatedIncome = _animatedSpots(incomeSpots, animation);
        final animatedExpense = _animatedSpots(expenseSpots, animation);

        return Opacity(
          opacity: animation,
          child: Transform.translate(
            offset: Offset(0, (1 - animation) * 18),
            child: ExpressiveCard(
              color: chartCardColor,
              surfaceTint: false,
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Income & Expenses',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                color: titleColor,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -.2,
                              ),
                        ),
                      ),
                      IconButton.filledTonal(
                        onPressed: () => showDateRangeSheet(context),
                        icon: const Icon(Icons.chevron_right_rounded),
                        style: IconButton.styleFrom(
                          backgroundColor: buttonBackground,
                          foregroundColor: buttonForeground,
                        ),
                        tooltip: 'Change date range',
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Container(
                    height: 300,
                    padding: const EdgeInsets.fromLTRB(4, 8, 10, 4),
                    decoration: BoxDecoration(
                      color: chartPanelColor,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: chartBorderColor),
                      boxShadow: [
                        BoxShadow(
                          color: panelShadowColor,
                          blurRadius: isDark ? 24.0 : 18.0,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: hasData
                        ? RepaintBoundary(
                            child: LineChart(
                              LineChartData(
                              minX: 0,
                              maxX: maxX,
                              minY: minY,
                              maxY: maxY,
                              clipData: const FlClipData.all(),
                              lineTouchData: LineTouchData(
                                handleBuiltInTouches: true,
                                touchTooltipData: LineTouchTooltipData(
                                  tooltipRoundedRadius: 16,
                                  tooltipPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  tooltipMargin: 12,
                                  getTooltipColor: (_) => Colors.black.withOpacity(.88),
                                  getTooltipItems: (items) => items.map((item) {
                                    final index = item.x.round().clamp(0, days.length - 1).toInt();
                                    final label = item.barIndex == 0 ? 'Income' : 'Expenses';
                                    return LineTooltipItem(
                                      '$label\n${DateFormat('MMM d').format(days[index])}  ${_compactCurrency(state, item.y)}',
                                      const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    );
                                  }).toList(),
                                ),
                              ),
                              borderData: FlBorderData(show: false),
                              gridData: FlGridData(
                                show: true,
                                drawVerticalLine: true,
                                horizontalInterval: maxY / 4,
                                verticalInterval: math.max(1, (maxX / 4).round()).toDouble(),
                                getDrawingHorizontalLine: (value) => FlLine(
                                  color: gridColor.withOpacity(isDark ? .20 : .44),
                                  strokeWidth: 1,
                                ),
                                getDrawingVerticalLine: (value) => FlLine(
                                  color: gridColor.withOpacity(isDark ? .16 : .34),
                                  strokeWidth: 1,
                                ),
                              ),
                              extraLinesData: ExtraLinesData(
                                verticalLines: [
                                  VerticalLine(
                                    x: highlightX,
                                    color: (isDark ? Colors.white : scheme.onSurface).withOpacity(isDark ? .34 : .42),
                                    strokeWidth: 1.6,
                                  ),
                                ],
                              ),
                              titlesData: FlTitlesData(
                                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                leftTitles: AxisTitles(
                                  sideTitles: SideTitles(
                                    showTitles: true,
                                    reservedSize: 58,
                                    interval: maxY / 4,
                                    getTitlesWidget: (value, meta) => _leftTitle(context, value, meta, maxY, axisColor),
                                  ),
                                ),
                                bottomTitles: AxisTitles(
                                  sideTitles: SideTitles(
                                    showTitles: true,
                                    reservedSize: 34,
                                    interval: 1,
                                    getTitlesWidget: (value, meta) => _bottomTitle(context, value, meta, axisColor),
                                  ),
                                ),
                              ),
                              lineBarsData: [
                                LineChartBarData(
                                  spots: animatedIncome,
                                  isCurved: true,
                                  preventCurveOverShooting: true,
                                  barWidth: 3.6,
                                  isStrokeCapRound: true,
                                  gradient: const LinearGradient(colors: [_incomeStart, _incomeEnd]),
                                  dotData: FlDotData(
                                    show: true,
                                    checkToShowDot: (spot, barData) => (spot.x - highlightX).abs() < .01,
                                    getDotPainter: (spot, percent, barData, index) => FlDotCirclePainter(
                                      radius: 6,
                                      color: Colors.white,
                                      strokeWidth: 3,
                                      strokeColor: _incomeEnd,
                                    ),
                                  ),
                                  belowBarData: BarAreaData(show: false),
                                ),
                                LineChartBarData(
                                  spots: animatedExpense,
                                  isCurved: true,
                                  preventCurveOverShooting: true,
                                  barWidth: 3.6,
                                  isStrokeCapRound: true,
                                  gradient: const LinearGradient(colors: [_expenseStart, _expenseEnd]),
                                  dotData: FlDotData(
                                    show: true,
                                    checkToShowDot: (spot, barData) => (spot.x - highlightX).abs() < .01,
                                    getDotPainter: (spot, percent, barData, index) => FlDotCirclePainter(
                                      radius: 6,
                                      color: Colors.white,
                                      strokeWidth: 3,
                                      strokeColor: _expenseEnd,
                                    ),
                                  ),
                                  belowBarData: BarAreaData(show: false),
                                ),
                              ],
                              ),
                            ),
                          )
                        : Center(
                            child: Text(
                              'No chart data exists for this range.',
                              style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: axisColor, fontWeight: FontWeight.w800),
                            ),
                          ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      _TrendLegend(color: _incomeEnd, label: 'Income', textColor: titleColor),
                      const SizedBox(width: 18),
                      _TrendLegend(color: _expenseStart, label: 'Expenses', textColor: titleColor),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TrendLegend extends StatelessWidget {
  const _TrendLegend({required this.color, required this.label, required this.textColor});

  final Color color;
  final String label;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 30,
          height: 6,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(999),
            boxShadow: [BoxShadow(color: color.withOpacity(.36), blurRadius: 10)],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: textColor.withOpacity(.88),
                fontWeight: FontWeight.w800,
              ),
        ),
      ],
    );
  }
}


class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key});

  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  CategoryType selected = CategoryType.expense;

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: 'Categories',
      subtitle: selected == CategoryType.expense ? 'Expense breakdown' : 'Income breakdown',
      child: ResponsiveContent(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SleekCyclePillSelector<CategoryType>(
              options: const [
                SleekPillOption(value: CategoryType.expense, label: 'Expense', icon: Icons.north_east_rounded),
                SleekPillOption(value: CategoryType.income, label: 'Income', icon: Icons.south_west_rounded),
              ],
              selected: selected,
              onChanged: (v) => setState(() => selected = v),
            ),
            const SizedBox(height: 14),
            CategoryBreakdownCard(key: ValueKey(selected), type: selected, interactive: true),
            const SizedBox(height: 18),
            _ManageCategoriesButton(type: selected),
          ],
        ),
      ),
    );
  }
}

class _ManageCategoriesButton extends StatelessWidget {
  const _ManageCategoriesButton({required this.type});
  final CategoryType type;

  @override
  Widget build(BuildContext context) {
    final label = type == CategoryType.expense ? 'Expense categories' : 'Income categories';
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(.52),
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ManageCategoriesScreen(type: type)),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(.28), width: .9),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: kSleekAccent.withOpacity(.16),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: kSleekAccent.withOpacity(.24)),
                ),
                child: const Icon(Icons.category_rounded, color: kSleekAccent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Manage categories', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
                    const SizedBox(height: 3),
                    Text(
                      label,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

class ManageCategoriesScreen extends StatelessWidget {
  const ManageCategoriesScreen({super.key, required this.type});
  final CategoryType type;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final cats = state.categories.where((c) => c.type == type && !c.isLoanSystemCategory).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final title = type == CategoryType.expense ? 'Expense categories' : 'Income categories';

    return PageScaffold(
      title: 'Manage categories',
      subtitle: title,
      actions: [IconButton(onPressed: () => showCategoryEditor(context, initialType: type), icon: const Icon(Icons.add_rounded))],
      child: ResponsiveListContent(
        itemCount: cats.length,
        empty: EmptyCard(
          icon: Icons.category_rounded,
          title: 'No ${enumName(type)} categories',
          body: 'Tap the + button to create a category.',
        ),
        itemBuilder: (context, index) {
          final category = cats[index];
          return CategoryTile(
            category: category,
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => showCategoryEditor(context, category: category),
          );
        },
      ),
    );
  }
}


class CategoryBreakdownCard extends StatelessWidget {
  const CategoryBreakdownCard({super.key, required this.type, this.interactive = false});
  final CategoryType type;
  final bool interactive;

  Color _fallbackColor(int index) {
    const palette = [
      Color(0xFF18D8CF),
      Color(0xFFA79BFF),
      Color(0xFF7EDBD3),
      Color(0xFF1EC7BD),
      Color(0xFFB9B1FF),
      Color(0xFF5BE6DB),
      Color(0xFFF7C66D),
      Color(0xFFF49DBE),
    ];
    return palette[index % palette.length];
  }

  List<_BreakdownSlice> _buildSlices(AppController state, List<MapEntry<String, double>> entries) {
    if (entries.length <= 8) {
      return entries.asMap().entries.map((indexed) {
        final index = indexed.key;
        final entry = indexed.value;
        final category = state.categoryOf(entry.key);
        final color = category == null ? _fallbackColor(index) : colorFromHex(category.iconColor, fallback: _fallbackColor(index));
        return _BreakdownSlice(categoryId: entry.key, category: category, value: entry.value, color: color);
      }).toList();
    }

    final visible = <_BreakdownSlice>[];
    for (var i = 0; i < 7; i++) {
      final entry = entries[i];
      final category = state.categoryOf(entry.key);
      final color = category == null ? _fallbackColor(i) : colorFromHex(category.iconColor, fallback: _fallbackColor(i));
      visible.add(_BreakdownSlice(categoryId: entry.key, category: category, value: entry.value, color: color));
    }
    final otherValue = entries.skip(7).fold<double>(0, (sum, entry) => sum + entry.value);
    visible.add(
      _BreakdownSlice(
        categoryId: '__other__',
        category: null,
        value: otherValue,
        color: _fallbackColor(7),
        labelOverride: 'Other',
        iconNameOverride: 'category',
      ),
    );
    return visible;
  }

  String _badgeTag(_BreakdownSlice slice) {
    if (slice.label.toLowerCase() == 'other') return 'OTHER';
    final words = slice.label
        .split(RegExp(r'\s+'))
        .where((w) => w.trim().isNotEmpty)
        .toList();
    if (words.isEmpty) return 'CAT';
    if (words.length >= 2) {
      return words.take(2).map((w) => w.substring(0, 1)).join().toUpperCase();
    }
    final word = words.first;
    if (word.length <= 4) return word.toUpperCase();
    return word.substring(0, 3).toUpperCase();
  }

  bool _useTextBadge(_BreakdownSlice slice) => slice.category == null;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final totals = state.categoryTotals(type);
    final entries = totals.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final total = entries.fold<double>(0, (sum, e) => sum + e.value);

    if (entries.isEmpty) {
      return ExpressiveCard(
        child: EmptyCard(
          icon: Icons.pie_chart_rounded,
          title: 'No ${enumName(type)} data',
          body: 'Transactions will appear here by category.',
        ),
      );
    }

    final slices = _buildSlices(state, entries);
    final chartTitle = type == CategoryType.expense ? 'Expense breakdown' : 'Income breakdown';
    final rangeLabel = state.activeRange().label;
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final chartSurfaceTop = isDark ? scheme.surfaceContainerHighest.withOpacity(.18) : const Color(0xFFF7FCFD);
    final chartSurfaceBottom = isDark ? scheme.surfaceContainerHigh.withOpacity(.06) : Colors.white;
    final chartBorderColor = isDark ? Colors.transparent : const Color(0xFFDCEBEE).withOpacity(.95);
    final donutTrackColor = isDark ? const Color(0xFF26383C).withOpacity(.36) : const Color(0xFFE1ECEF);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExpressiveCard(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          chartTitle,
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: () => showDateRangeSheet(context),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: isDark ? scheme.surfaceContainerHigh.withOpacity(.88) : const Color(0xFFEAF3F5).withOpacity(.94),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: isDark ? scheme.outline.withOpacity(.16) : const Color(0xFFD8E7EA)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              rangeLabel,
                              style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(width: 4),
                            Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: scheme.onSurfaceVariant),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 334,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final canvasWidth = constraints.maxWidth;
                    const canvasHeight = 334.0;
                    final chartSize = math.min(math.max(180.0, canvasWidth - 98), math.min(268.0, canvasWidth - 8));
                    final centerSize = chartSize * .57;
                    final manyBadges = slices.length > 5;
                    final badgeWidth = manyBadges ? (canvasWidth < 360 ? 78.0 : 86.0) : (canvasWidth < 360 ? 84.0 : 94.0);
                    final badgeHeight = manyBadges ? 40.0 : 44.0;
                    final badgeOrbit = (chartSize / 2) + (manyBadges ? 32.0 : 24.0);

                    double startAngle = -90;
                    final badgeAngles = <double>[];
                    for (final slice in slices) {
                      final sweep = total == 0 ? 0 : (slice.value / total) * 360;
                      badgeAngles.add(startAngle + (sweep / 2));
                      startAngle += sweep;
                    }

                    final badgeNudges = List<double>.filled(slices.length, 0);
                    void spreadDenseSide(bool leftSide) {
                      final indexes = <int>[];
                      for (var i = 0; i < badgeAngles.length; i++) {
                        final radians = badgeAngles[i] * (math.pi / 180);
                        final isLeft = math.cos(radians) < -0.18;
                        if (isLeft == leftSide) indexes.add(i);
                      }
                      if (indexes.length <= 1) return;
                      indexes.sort((a, b) {
                        final ay = math.sin(badgeAngles[a] * (math.pi / 180));
                        final by = math.sin(badgeAngles[b] * (math.pi / 180));
                        return ay.compareTo(by);
                      });
                      final spacing = manyBadges ? 11.0 : 8.0;
                      for (var rank = 0; rank < indexes.length; rank++) {
                        badgeNudges[indexes[rank]] = (rank - ((indexes.length - 1) / 2)) * spacing;
                      }
                    }

                    spreadDenseSide(true);
                    spreadDenseSide(false);

                    int? selectedBadgeIndex;

                    return StatefulBuilder(
                      builder: (context, setBadgeState) {
                        return TweenAnimationBuilder<double>(
                      key: ValueKey('${type.name}-${slices.length}-${total.toStringAsFixed(2)}'),
                      tween: Tween<double>(begin: 0, end: 1),
                      duration: const Duration(milliseconds: 680),
                      curve: Curves.easeOutCubic,
                      builder: (context, progress, _) {
                        final badgeProgress = ((progress - .35) / .65).clamp(0.0, 1.0).toDouble();
                        final centerProgress = ((progress - .18) / .82).clamp(0.0, 1.0).toDouble();
                        final badgeOrder = List<int>.generate(slices.length, (index) => index);
                        if (selectedBadgeIndex != null && selectedBadgeIndex! >= 0 && selectedBadgeIndex! < slices.length) {
                          badgeOrder
                            ..remove(selectedBadgeIndex)
                            ..add(selectedBadgeIndex!);
                        }

                        return Stack(
                          alignment: Alignment.center,
                          clipBehavior: Clip.hardEdge,
                          children: [
                            Positioned.fill(
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(34),
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      chartSurfaceTop,
                                      chartSurfaceBottom,
                                    ],
                                  ),
                                  border: Border.all(color: chartBorderColor, width: isDark ? 0.0 : 1.0),
                                  boxShadow: isDark
                                      ? null
                                      : [
                                          BoxShadow(
                                            color: Colors.black.withOpacity(.035),
                                            blurRadius: 18,
                                            offset: const Offset(0, 8),
                                          ),
                                        ],
                                ),
                              ),
                            ),
                            Center(
                              child: SizedBox(
                                width: chartSize,
                                height: chartSize,
                                child: RepaintBoundary(
                                  child: CustomPaint(
                                    isComplex: true,
                                    willChange: progress < 1,
                                    painter: _ExpressiveDonutPainter(slices: slices, total: total, progress: progress, trackColor: donutTrackColor),
                                  ),
                                ),
                              ),
                            ),
                            for (final i in badgeOrder)
                              _DonutBadgePositioned(
                                angleDegrees: badgeAngles[i],
                                orbit: badgeOrbit,
                                canvasWidth: canvasWidth,
                                canvasHeight: canvasHeight,
                                badgeWidth: selectedBadgeIndex == i ? badgeWidth + 12 : badgeWidth,
                                badgeHeight: selectedBadgeIndex == i ? badgeHeight + 4 : badgeHeight,
                                verticalNudge: badgeNudges[i],
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    setBadgeState(() {
                                      selectedBadgeIndex = selectedBadgeIndex == i ? null : i;
                                    });
                                  },
                                  child: Opacity(
                                    opacity: badgeProgress,
                                    child: Transform.scale(
                                      scale: (.86 + (.14 * badgeProgress)) * (selectedBadgeIndex == i ? 1.08 : 1.0),
                                      child: _DonutPercentBadge(
                                        color: slices[i].color,
                                        iconName: slices[i].iconName,
                                        label: total <= 0 ? '0%' : '${((slices[i].value / total) * 100).round()}%',
                                        leadingText: _badgeTag(slices[i]),
                                        useTextBadge: _useTextBadge(slices[i]),
                                        selected: selectedBadgeIndex == i,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            Center(
                              child: Opacity(
                                opacity: centerProgress,
                                child: Transform.scale(
                                  scale: .92 + (.08 * centerProgress),
                                  child: Container(
                                    width: centerSize,
                                    height: centerSize,
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                    decoration: BoxDecoration(
                                      color: isDark ? const Color(0xFF111417).withOpacity(.97) : Colors.white.withOpacity(.98),
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(isDark ? .22 : .08),
                                          blurRadius: isDark ? 22.0 : 18.0,
                                          offset: const Offset(0, 10),
                                        ),
                                      ],
                                      border: Border.all(
                                        color: isDark ? scheme.outline.withOpacity(.10) : const Color(0xFFD7E6E9),
                                      ),
                                    ),
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Flexible(
                                          flex: 3,
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            child: Text(
                                              state.format(total),
                                              maxLines: 1,
                                              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                                    fontWeight: FontWeight.w900,
                                                    letterSpacing: -.8,
                                                    color: isDark ? Colors.white : scheme.onSurface,
                                                  ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 5),
                                        Flexible(
                                          flex: 2,
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            child: Text(
                                              type == CategoryType.expense ? 'Total expense' : 'Total income',
                                              maxLines: 1,
                                              textAlign: TextAlign.center,
                                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                                    color: const Color(0xFF10CADA),
                                                    fontWeight: FontWeight.w900,
                                                  ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Flexible(
                                          flex: 2,
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            child: Text(
                                              rangeLabel,
                                              maxLines: 1,
                                              textAlign: TextAlign.center,
                                              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                                    color: isDark ? Colors.white.withOpacity(.82) : scheme.onSurfaceVariant.withOpacity(.88),
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ...slices.asMap().entries.map((indexed) {
          final slice = indexed.value;
          final color = slice.color;
          final percentage = total <= 0 ? 0.0 : (slice.value / total) * 100;

          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: ExpressiveCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: interactive && slice.category != null
                      ? () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => CategoryTransactionScreen(category: slice.category!)),
                          )
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                    child: Row(
                      children: [
                        iconBubble(context, slice.iconName, colorToHex(color), size: 50),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                slice.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${percentage.toStringAsFixed(1)}%',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w800),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          state.format(slice.value),
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900),
                        ),
                        if (interactive && slice.category != null) ...[
                          const SizedBox(width: 8),
                          Icon(Icons.chevron_right_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ],
    );
  }
}

class _BreakdownSlice {
  const _BreakdownSlice({
    required this.categoryId,
    required this.category,
    required this.value,
    required this.color,
    this.labelOverride,
    this.iconNameOverride,
  });

  final String categoryId;
  final Category? category;
  final double value;
  final Color color;
  final String? labelOverride;
  final String? iconNameOverride;

  String get label => labelOverride ?? category?.name ?? 'Unknown';
  String get iconName => iconNameOverride ?? category?.iconName ?? 'category';
}

class _ExpressiveDonutPainter extends CustomPainter {
  const _ExpressiveDonutPainter({required this.slices, required this.total, required this.progress, required this.trackColor});

  final List<_BreakdownSlice> slices;
  final double total;
  final double progress;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final strokeWidth = size.shortestSide * .125;
    final radius = (size.shortestSide - strokeWidth) / 2 - 3;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.butt
      ..color = trackColor;
    canvas.drawCircle(center, radius, trackPaint);

    if (total <= 0) return;

    var start = -math.pi / 2;
    for (final slice in slices) {
      final sweep = (slice.value / total) * math.pi * 2;
      final animatedSweep = sweep * progress;
      if (animatedSweep <= 0) {
        start += sweep;
        continue;
      }
      final gap = animatedSweep > .08 ? .025 : 0.0;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.butt
        ..color = slice.color;
      canvas.drawArc(rect, start + (gap / 2), math.max(0, animatedSweep - gap), false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _ExpressiveDonutPainter oldDelegate) {
    return oldDelegate.slices != slices || oldDelegate.total != total || oldDelegate.progress != progress || oldDelegate.trackColor != trackColor;
  }
}

class _DonutBadgePositioned extends StatelessWidget {
  const _DonutBadgePositioned({
    required this.angleDegrees,
    required this.orbit,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.badgeWidth,
    required this.badgeHeight,
    this.verticalNudge = 0,
    required this.child,
  });

  final double angleDegrees;
  final double orbit;
  final double canvasWidth;
  final double canvasHeight;
  final double badgeWidth;
  final double badgeHeight;
  final double verticalNudge;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final radians = angleDegrees * (math.pi / 180);
    final center = Offset(canvasWidth / 2, canvasHeight / 2);
    final rawLeft = center.dx + math.cos(radians) * orbit - (badgeWidth / 2);
    final rawTop = center.dy + math.sin(radians) * orbit - (badgeHeight / 2) + verticalNudge;
    final left = rawLeft.clamp(0.0, math.max(0.0, canvasWidth - badgeWidth)).toDouble();
    final top = rawTop.clamp(0.0, math.max(0.0, canvasHeight - badgeHeight)).toDouble();

    return Positioned(
      left: left,
      top: top,
      width: badgeWidth,
      height: badgeHeight,
      child: child,
    );
  }
}

class _DonutPercentBadge extends StatelessWidget {
  const _DonutPercentBadge({
    required this.color,
    required this.iconName,
    required this.label,
    required this.leadingText,
    required this.useTextBadge,
    this.selected = false,
  });

  final Color color;
  final String iconName;
  final String label;
  final String leadingText;
  final bool useTextBadge;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final badgeBackground = selected
        ? (isDark ? color.withOpacity(.28) : color.withOpacity(.20))
        : (isDark ? const Color(0xFF181B1F).withOpacity(.96) : Colors.white.withOpacity(.96));
    final badgeBorder = selected ? color.withOpacity(isDark ? .88 : .72) : (isDark ? Colors.white.withOpacity(.05) : const Color(0xFFD8E6EA));
    final textColor = isDark ? Colors.white.withOpacity(.96) : scheme.onSurface;
    final iconBackground = useTextBadge
        ? (isDark ? Colors.black : const Color(0xFFF3F8F9))
        : color.withOpacity(isDark ? .18 : .16);
    final iconBorder = useTextBadge
        ? (isDark ? Colors.white.withOpacity(.06) : const Color(0xFFDCEBED))
        : color.withOpacity(isDark ? .28 : .30);
    final iconColor = isDark ? Colors.white : color;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
      decoration: BoxDecoration(
        color: badgeBackground,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: badgeBorder, width: selected ? 2.0 : 1.0),
        boxShadow: [
          BoxShadow(
            color: selected ? color.withOpacity(isDark ? .34 : .22) : Colors.black.withOpacity(isDark ? .26 : .10),
            blurRadius: selected ? 22.0 : (isDark ? 18.0 : 14.0),
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: iconBackground,
              shape: BoxShape.circle,
              border: Border.all(color: iconBorder),
            ),
            child: Center(
              child: useTextBadge
                  ? FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        child: Text(
                          leadingText,
                          maxLines: 1,
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: textColor,
                                fontWeight: FontWeight.w900,
                                letterSpacing: .4,
                              ),
                        ),
                      ),
                    )
                  : iconGlyph(context, iconName, color: iconColor, size: 15, imageBackground: Colors.white.withOpacity(.90)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                label,
                maxLines: 1,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                      letterSpacing: -.2,
                      color: textColor,
                    ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CategoryTransactionScreen extends StatelessWidget {
  const CategoryTransactionScreen({super.key, required this.category});
  final Category category;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final txs = state.filteredTransactions(categoryId: category.id, ignoreDate: true);
    return PageScaffold(
      title: category.name,
      subtitle: '${txs.length} transactions',
      actions: [IconButton(onPressed: () => showTransactionEditor(context, lockedCategory: category), icon: const Icon(Icons.add_rounded))],
      child: ResponsiveListContent(
        itemCount: txs.length,
        empty: const EmptyCard(icon: Icons.receipt_long_rounded, title: 'No transactions', body: 'Transactions for this category will appear here.'),
        itemBuilder: (context, index) => TransactionTile(tx: txs[index]),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Budgets
// -----------------------------------------------------------------------------

class BudgetListScreen extends StatelessWidget {
  const BudgetListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final progress = state.budgetProgress();
    return PageScaffold(
      title: 'Budgets',
      actions: [IconButton(onPressed: () => showBudgetEditor(context), icon: const Icon(Icons.add_rounded))],
      child: ResponsiveContent(
        child: progress.isEmpty
            ? EmptyCard(icon: Icons.savings_rounded, title: 'No budgets', body: 'Create a monthly budget for all accounts/categories or selected scopes.', action: () => showBudgetEditor(context), actionLabel: 'Create budget')
            : Column(
                children: progress
                    .map(
                      (p) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: BudgetProgressTile(
                          progress: p,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => BudgetDetailScreen(progress: p),
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
      ),
    );
  }
}

class BudgetProgressTile extends StatelessWidget {
  const BudgetProgressTile({super.key, required this.progress, this.onTap});
  final BudgetProgress progress;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final ratio = progress.ratio;
    final color = ratio >= 1 ? Colors.red : ratio >= .8 ? Colors.deepOrange : ratio >= .5 ? Colors.orange : Colors.green;
    return ExpressiveCard(
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              iconBubble(context, 'wallet', colorToHex(color)),
              const SizedBox(width: 12),
              Expanded(child: Text(DateFormat('MMMM yyyy').format(progress.budget.selectedMonth), style: const TextStyle(fontWeight: FontWeight.w900))),
              Text('${(ratio * 100).clamp(0, 999).toStringAsFixed(0)}%', style: const TextStyle(fontWeight: FontWeight.w900)),
            ]),
            const SizedBox(height: 12),
            ClipRRect(borderRadius: BorderRadius.circular(99), child: LinearProgressIndicator(value: ratio.clamp(0, 1).toDouble(), minHeight: 12, color: color)),
            const SizedBox(height: 8),
            Text('${state.format(progress.spent)} spent of ${state.format(progress.budget.amount)}'),
          ],
        ),
      ),
    );
  }
}

class BudgetDetailScreen extends StatelessWidget {
  const BudgetDetailScreen({super.key, required this.progress});
  final BudgetProgress progress;

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: 'Budget detail',
      subtitle: DateFormat('MMMM yyyy').format(progress.budget.selectedMonth),
      actions: [IconButton(onPressed: () => showBudgetEditor(context, budget: progress.budget), icon: const Icon(Icons.edit_rounded)), IconButton(onPressed: () => showTransactionEditor(context), icon: const Icon(Icons.add_rounded))],
      child: ResponsiveContent(
        child: Column(
          children: [
            BudgetProgressTile(progress: progress),
            const SectionHeader('Transactions under this budget'),
            if (progress.transactions.isEmpty) const EmptyCard(icon: Icons.receipt_long_rounded, title: 'No spending', body: 'Spending matching this budget scope will appear here.') else ...progress.transactions.map((tx) => Padding(padding: const EdgeInsets.only(bottom: 10), child: TransactionTile(tx: tx))),
          ],
        ),
      ),
    );
  }
}

Future<void> showBudgetEditor(BuildContext context, {Budget? budget}) async {
  await showKoinlyPopup<void>(
    context,
    maxWidth: 560,
    maxHeight: 700,
    child: BudgetEditor(budget: budget),
  );
}

class BudgetEditor extends StatefulWidget {
  const BudgetEditor({super.key, this.budget});
  final Budget? budget;

  @override
  State<BudgetEditor> createState() => _BudgetEditorState();
}

class _BudgetEditorState extends State<BudgetEditor> {
  final amount = TextEditingController();
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  bool allAccounts = true;
  bool allCategories = true;
  List<String> accountIds = [];
  List<String> categoryIds = [];

  @override
  void initState() {
    super.initState();
    final b = widget.budget;
    if (b != null) {
      amount.text = b.amount.toStringAsFixed(2);
      month = b.selectedMonth;
      allAccounts = b.allAccountsSelected;
      allCategories = b.allCategoriesSelected;
      accountIds = List.of(b.accountIds);
      categoryIds = List.of(b.categoryIds);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 14),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.budget == null ? 'Create budget' : 'Edit budget', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 16),
            TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Budget amount')),
            const SizedBox(height: 12),
            OutlinedButton.icon(onPressed: () async { final d = await pickDate(context, month); if (d != null) setState(() => month = DateTime(d.year, d.month)); }, icon: const Icon(Icons.calendar_month_rounded), label: Text(DateFormat('MMMM yyyy').format(month))),
            SwitchListTile(value: allAccounts, onChanged: (v) => setState(() => allAccounts = v), title: const Text('Apply to all accounts')),
            if (!allAccounts) Wrap(spacing: 8, runSpacing: 8, children: state.accounts.map((a) => FilterChip(label: Text(a.name), selected: accountIds.contains(a.id), onSelected: (v) => setState(() => v ? accountIds.add(a.id) : accountIds.remove(a.id)))).toList()),
            SwitchListTile(value: allCategories, onChanged: (v) => setState(() => allCategories = v), title: const Text('Apply to all categories')),
            if (!allCategories) Wrap(spacing: 8, runSpacing: 8, children: state.categories.where((c) => c.type == CategoryType.expense).map((c) => FilterChip(label: Text(c.name), selected: categoryIds.contains(c.id), onSelected: (v) => setState(() => v ? categoryIds.add(c.id) : categoryIds.remove(c.id)))).toList()),
            const SizedBox(height: 18),
            Row(children: [
              if (widget.budget != null) Expanded(child: OutlinedButton(onPressed: () async { await state.deleteBudget(widget.budget!.id); if (context.mounted) Navigator.pop(context); }, child: const Text('Delete'))),
              if (widget.budget != null) const SizedBox(width: 12),
              Expanded(flex: 2, child: FilledButton(onPressed: () async {
                final value = double.tryParse(amount.text) ?? 0;
                if (value <= 0) return;
                final now = DateTime.now();
                final budget = Budget(id: widget.budget?.id ?? _uuid.v4(), selectedMonth: month, amount: value, allAccountsSelected: allAccounts, allCategoriesSelected: allCategories, accountIds: allAccounts ? [] : accountIds, categoryIds: allCategories ? [] : categoryIds, createdOn: widget.budget?.createdOn ?? now, updatedOn: now);
                await state.saveBudget(budget);
                if (context.mounted) Navigator.pop(context);
              }, child: const Text('Save'))),
            ]),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Loans
// -----------------------------------------------------------------------------

class LoansScreen extends StatefulWidget {
  const LoansScreen({super.key});

  @override
  State<LoansScreen> createState() => _LoansScreenState();
}

class _LoansScreenState extends State<LoansScreen> {
  LoanType type = LoanType.given;
  bool completed = false;
  bool _loadedInitialType = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loadedInitialType) {
      type = context.read<AppController>().activeLoanType;
      _loadedInitialType = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final visible = state.loans.where((l) => l.type == type && (completed ? l.isCompleted : !l.isCompleted)).toList();
    final typeLoans = state.loans.where((l) => l.type == type).toList();
    final reminderItems = state.loanRepaymentReminders.where((r) => !r.isPaid && state.loanOf(r.loanId)?.type == type).toList()..sort((a, b) => a.dueDate.compareTo(b.dueDate));
    final totalPrincipal = typeLoans.fold<double>(0, (s, l) => s + l.amount);
    final totalRepaid = typeLoans.fold<double>(0, (s, l) => s + l.repaidAmount);
    final totalRemaining = typeLoans.fold<double>(0, (s, l) => s + l.remainingAmount);
    return PageScaffold(
      title: 'Loans',
      subtitle: type == LoanType.given ? 'Money you gave' : 'Money you borrowed',
      child: ResponsiveContent(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SleekCyclePillSelector<LoanType>(
              options: const [
                SleekPillOption(value: LoanType.given, label: 'Given', icon: Icons.call_made_rounded),
                SleekPillOption(value: LoanType.taken, label: 'Taken', icon: Icons.call_received_rounded),
              ],
              selected: type,
              onChanged: (v) {
                setState(() => type = v);
                context.read<AppController>().activeLoanType = v;
              },
            ),
            const SizedBox(height: 10),
            SleekCyclePillSelector<bool>(
              options: const [
                SleekPillOption(value: false, label: 'Open', icon: Icons.pending_actions_rounded),
                SleekPillOption(value: true, label: 'Completed', icon: Icons.check_circle_rounded),
              ],
              selected: completed,
              onChanged: (v) => setState(() => completed = v),
            ),
            const SizedBox(height: 14),
            ExpressiveCard(child: Column(children: [
              MiniMetric('Remaining balance', state.format(totalRemaining), Icons.account_balance_wallet_rounded),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: LoanSummaryMetric(label: 'Principal', value: state.format(totalPrincipal), icon: Icons.flag_rounded)),
                const SizedBox(width: 10),
                Expanded(child: LoanSummaryMetric(label: 'Repaid', value: state.format(totalRepaid), icon: Icons.done_all_rounded)),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: LoanSummaryMetric(label: 'Open', value: '${typeLoans.where((e) => !e.isCompleted).length}', icon: Icons.pending_actions_rounded)),
                const SizedBox(width: 10),
                Expanded(child: LoanSummaryMetric(label: 'Completed', value: '${typeLoans.where((e) => e.isCompleted).length}', icon: Icons.check_circle_rounded)),
              ]),
            ])),
            if (reminderItems.isNotEmpty) ...[
              const SectionHeader('Repayment reminders'),
              ...reminderItems.take(3).map((reminder) {
                final loan = state.loanOf(reminder.loanId);
                if (loan == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: LoanReminderTile(
                    loan: loan,
                    reminder: reminder,
                    onPaid: () => state.markLoanRepaymentReminderPaid(loan, reminder, reminder.accountId.isNotEmpty ? reminder.accountId : loan.accountId),
                    onDelete: () => state.deleteLoanRepaymentReminder(reminder.id),
                  ),
                );
              }),
            ],
            const SectionHeader('Loan records'),
            if (visible.isEmpty)
              const EmptyCard(
                icon: Icons.handshake_rounded,
                title: 'No loans here',
                body: 'Create a loan. The selected account balance will update directly without adding income or expense records.',
              )
            else
              ...visible.map((loan) => Padding(padding: const EdgeInsets.only(bottom: 10), child: LoanTile(loan: loan))),
          ],
        ),
      ),
    );
  }
}

class LoanSummaryMetric extends StatelessWidget {
  const LoanSummaryMetric({super.key, required this.label, required this.value, required this.icon});
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    Widget scaleText(String text, TextStyle? style, {FontWeight? weight}) {
      return FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.visible,
          style: style?.copyWith(fontWeight: weight),
        ),
      );
    }

    return Container(
      constraints: const BoxConstraints(minHeight: 86),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withOpacity(.55),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Icon(icon, size: 28),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: double.infinity, child: scaleText(label, textTheme.bodyLarge)),
                const SizedBox(height: 5),
                SizedBox(width: double.infinity, child: scaleText(value, textTheme.titleMedium, weight: FontWeight.w900)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


class LoanTile extends StatelessWidget {
  const LoanTile({super.key, required this.loan});
  final Loan loan;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final progress = loan.amount <= 0 ? 0.0 : loan.repaidAmount / loan.amount;
    final reminders = state.loanRemindersFor(loan.id);
    final overdue = reminders.any((r) => r.isOverdue);
    final nextReminder = reminders.where((r) => !r.isPaid).toList()..sort((a, b) => a.dueDate.compareTo(b.dueDate));
    final accent = overdue ? kSleekExpense : (loan.type == LoanType.given ? const Color(0xFFFF7A7A) : const Color(0xFF38BDF8));
    return ExpressiveCard(
      color: overdue
          ? (Theme.of(context).brightness == Brightness.dark ? const Color(0xFF2A1719) : const Color(0xFFFFF0F0))
          : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => LoanDetailScreen(loanId: loan.id))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              iconBubble(context, loan.type == LoanType.given ? 'loan_given' : 'loan_taken', colorToHex(accent), size: 46),
              const SizedBox(width: 12),
              Expanded(
                child: Text(loan.personName, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(state.format(loan.remainingAmount), style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900)),
                  Text(overdue ? 'Overdue' : (loan.isCompleted ? 'Completed' : 'Open'), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: overdue ? kSleekExpense : (loan.isCompleted ? kSleekIncome : kSleekAccent), fontWeight: FontWeight.w900)),
                ],
              ),
            ]),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                minHeight: 6,
                value: progress.clamp(0, 1).toDouble(),
                color: accent,
                backgroundColor: accent.withOpacity(.16),
              ),
            ),
            const SizedBox(height: 9),
            Text(
              '${state.format(loan.repaidAmount)} repaid of ${state.format(loan.amount)} • ${DateFormat('MMM d, yyyy').format(loan.loanDate)}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
            ),
            if (nextReminder.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '${nextReminder.first.isOverdue ? 'Overdue' : 'Next repayment'}: ${state.format(nextReminder.first.amount)} • ${DateFormat('MMM d, yyyy').format(nextReminder.first.dueDate)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: nextReminder.first.isOverdue ? kSleekExpense : kSleekWarning, fontWeight: FontWeight.w900),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              '${loan.type == LoanType.given ? 'Paid from' : 'Received into'}: ${state.accountOf(loan.accountId)?.name ?? 'Unknown account'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }
}


class LoanDetailScreen extends StatelessWidget {
  const LoanDetailScreen({super.key, required this.loanId});
  final String loanId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final loan = state.loans.where((l) => l.id == loanId).firstOrNull;
    if (loan == null) return const Scaffold(body: Center(child: Text('Loan not found')));
    return FutureBuilder<List<LoanRepayment>>(
      future: state.database.repayments(loan.id),
      builder: (context, snapshot) {
        final repayments = snapshot.data ?? [];
        final reminders = state.loanRemindersFor(loan.id);
        final pendingReminders = reminders.where((r) => !r.isPaid).toList()..sort((a, b) => a.dueDate.compareTo(b.dueDate));
        return PageScaffold(
          title: loan.personName,
          subtitle: loan.type == LoanType.given ? 'Given loan' : 'Taken loan',
          actions: [
            IconButton(onPressed: () => showLoanEditor(context, loan: loan), icon: const Icon(Icons.edit_rounded)),
            IconButton(onPressed: () => showRepaymentEditor(context, loan), icon: const Icon(Icons.payments_rounded)),
          ],
          child: ResponsiveContent(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LoanTile(loan: loan),
                const SectionHeader('Details'),
                ExpressiveCard(child: Column(children: [
                  _detailRow(loan.type == LoanType.given ? 'Paid from' : 'Received into', state.accountOf(loan.accountId)?.name ?? 'Unknown'),
                  _detailRow('Loan date', DateFormat('MMM d, yyyy').format(loan.loanDate)),
                  _detailRow('Due date', loan.dueDate == null ? 'Not set' : DateFormat('MMM d, yyyy').format(loan.dueDate!)),
                  _detailRow('Notes', loan.notes.isEmpty ? 'No notes' : loan.notes),
                ])),
                const SectionHeader('Repayment reminders'),
                if (pendingReminders.isEmpty)
                  const EmptyCard(icon: Icons.notifications_active_rounded, title: 'No repayment reminders', body: 'Add repayment dates while creating or editing this loan.')
                else
                  ...pendingReminders.map((r) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: LoanReminderTile(
                          loan: loan,
                          reminder: r,
                          onPaid: () => state.markLoanRepaymentReminderPaid(loan, r, r.accountId.isNotEmpty ? r.accountId : loan.accountId),
                          onDelete: () => state.deleteLoanRepaymentReminder(r.id),
                        ),
                      )),
                const SectionHeader('Repayment history'),
                if (repayments.isEmpty) const EmptyCard(icon: Icons.history_rounded, title: 'No repayments', body: 'Repayment records will appear here.') else ...repayments.map((r) => Padding(padding: const EdgeInsets.only(bottom: 10), child: ExpressiveCard(padding: const EdgeInsets.all(12), child: ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.payments_rounded), title: Text(state.format(r.amount), style: const TextStyle(fontWeight: FontWeight.w900)), subtitle: Text('${DateFormat('MMM d, yyyy').format(r.paidOn)} • ${state.accountOf(r.accountId.isNotEmpty ? r.accountId : loan.accountId)?.name ?? 'Unknown account'}${r.notes.isEmpty ? '' : ' • ${r.notes}'}'), trailing: IconButton(icon: const Icon(Icons.delete_outline_rounded), onPressed: () => state.deleteRepayment(r.id))))))
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _detailRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(width: 96, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800))), Expanded(child: Text(value))]),
      );
}

Future<void> showLoanEditor(BuildContext context, {Loan? loan, LoanType initialType = LoanType.given}) async {
  await showKoinlyPopup<void>(
    context,
    maxWidth: 560,
    maxHeight: 700,
    child: LoanEditor(loan: loan, initialType: initialType),
  );
}

class LoanEditor extends StatefulWidget {
  const LoanEditor({super.key, this.loan, required this.initialType});
  final Loan? loan;
  final LoanType initialType;

  @override
  State<LoanEditor> createState() => _LoanEditorState();
}

class _LoanEditorState extends State<LoanEditor> {
  final person = TextEditingController();
  final amount = TextEditingController();
  final notes = TextEditingController();
  LoanType type = LoanType.given;
  String? accountId;
  DateTime loanDate = DateTime.now();
  DateTime? dueDate;
  final List<_LoanReminderDraft> reminderDrafts = [];

  @override
  void initState() {
    super.initState();
    final state = context.read<AppController>();
    final loan = widget.loan;
    if (loan != null) {
      person.text = loan.personName;
      amount.text = loan.amount.toStringAsFixed(2);
      notes.text = loan.notes;
      type = loan.type;
      accountId = loan.accountId;
      loanDate = loan.loanDate;
      dueDate = loan.dueDate;
      reminderDrafts.addAll(state.loanRemindersFor(loan.id).where((r) => !r.isPaid).map((r) => _LoanReminderDraft.fromReminder(r)));
    } else {
      type = widget.initialType;
      accountId = state.defaultAccountId ?? state.operatingAccounts.firstOrNull?.id;
    }
    if (reminderDrafts.isEmpty && dueDate != null) {
      reminderDrafts.add(_LoanReminderDraft(amount: amount.text.isEmpty ? '0' : amount.text, dueDate: dueDate!, reminderTimeMinutes: 9 * 60, notes: ''));
    }
  }

  @override
  void dispose() {
    person.dispose();
    amount.dispose();
    notes.dispose();
    for (final draft in reminderDrafts) {
      draft.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final accountOptions = state.operatingAccounts.isEmpty ? state.accounts : state.operatingAccounts;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 14),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.loan == null ? 'Add loan' : 'Edit loan', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 16),
            SleekPillSelector<LoanType>(
              options: const [
                SleekPillOption(value: LoanType.given, label: 'Given Loans', icon: Icons.call_made_rounded),
                SleekPillOption(value: LoanType.taken, label: 'Taken Loans', icon: Icons.call_received_rounded),
              ],
              selected: type,
              onChanged: (v) => setState(() => type = v),
            ),
            const SizedBox(height: 12),
            TextField(controller: person, decoration: InputDecoration(labelText: type == LoanType.given ? 'Borrower name' : 'Lender name')),
            const SizedBox(height: 12),
            TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Loan amount')),
            const SizedBox(height: 12),
            AppleSelectionField(
              label: type == LoanType.given ? 'Paid from account' : 'Receive money into account',
              option: accountOptions.where((a) => a.id == accountId).firstOrNull == null ? null : optionFromAccount(accountOptions.where((a) => a.id == accountId).first, state),
              emptyText: 'Choose account',
              onTap: () async {
                final selected = await showAppleWheelSelectionSheet(
                  context,
                  title: type == LoanType.given ? 'Choose Paid From Account' : 'Choose Receiving Account',
                  selectedId: accountId,
                  options: accountOptions.map((a) => optionFromAccount(a, state)).toList(),
                );
                if (selected != null) setState(() => accountId = selected);
              },
            ),
            const SizedBox(height: 6),
            Text(
              type == LoanType.given
                  ? 'Given loans decrease the selected account balance.'
                  : 'Taken loans increase the selected account balance.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: OutlinedButton.icon(onPressed: () async { final d = await pickDate(context, loanDate); if (d != null) setState(() => loanDate = d); }, icon: const Icon(Icons.date_range_rounded), label: Text(DateFormat('MMM d, yyyy').format(loanDate)))),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton.icon(onPressed: () async { final d = await pickDate(context, dueDate ?? loanDate); if (d != null) setState(() => dueDate = d); }, icon: const Icon(Icons.event_available_rounded), label: Text(dueDate == null ? 'Due date' : DateFormat('MMM d').format(dueDate!)))),
            ]),
            const SizedBox(height: 12),
            TextField(controller: notes, minLines: 1, maxLines: 3, decoration: const InputDecoration(labelText: 'Notes')),
            const SizedBox(height: 14),
            ExpressiveCard(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text('Repayment reminders', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900))),
                      IconButton(
                        onPressed: () => setState(() => reminderDrafts.add(_LoanReminderDraft(amount: amount.text.isEmpty ? '0' : amount.text, dueDate: dueDate ?? loanDate.add(const Duration(days: 30)), reminderTimeMinutes: 9 * 60, notes: ''))),
                        icon: const Icon(Icons.add_alert_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    type == LoanType.given
                        ? 'Schedule expected repayments you should receive from the borrower.'
                        : 'Schedule repayments you need to pay back to the lender.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  if (reminderDrafts.isEmpty)
                    const Text('No repayment reminders added yet.')
                  else
                    ...reminderDrafts.asMap().entries.map((entry) => _LoanReminderDraftTile(
                          draft: entry.value,
                          index: entry.key,
                          onChanged: () => setState(() {}),
                          onRemove: () => setState(() {
                            final removed = reminderDrafts.removeAt(entry.key);
                            removed.dispose();
                          }),
                        )),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Row(children: [
              if (widget.loan != null) Expanded(child: OutlinedButton(onPressed: () async { await state.deleteLoan(widget.loan!.id); if (context.mounted) Navigator.pop(context); }, child: const Text('Delete'))),
              if (widget.loan != null) const SizedBox(width: 12),
              Expanded(flex: 2, child: FilledButton(onPressed: () async {
                final value = double.tryParse(amount.text) ?? 0;
                if (value <= 0 || person.text.trim().isEmpty || accountId == null) return;
                final now = DateTime.now();
                final loanId = widget.loan?.id ?? _uuid.v4();
                final loan = Loan(id: loanId, type: type, accountId: accountId!, personName: person.text.trim(), amount: value, loanDate: loanDate, dueDate: dueDate, notes: notes.text.trim(), repaidAmount: widget.loan?.repaidAmount ?? 0, status: widget.loan?.status ?? LoanStatus.open, createdOn: widget.loan?.createdOn ?? now, updatedOn: now);
                if (widget.loan == null) { await state.addLoan(loan); } else { await state.updateLoan(loan); }
                final reminders = reminderDrafts
                    .where((draft) => (double.tryParse(draft.amount.text) ?? 0) > 0)
                    .map((draft) => draft.toReminder(loanId: loan.id, accountId: accountId!, now: now))
                    .toList();
                await state.replaceLoanRepaymentReminders(loan.id, reminders);
                if (context.mounted) Navigator.pop(context);
              }, child: const Text('Save'))),
            ]),
          ],
        ),
      ),
    );
  }
}


class LoanReminderTile extends StatelessWidget {
  const LoanReminderTile({super.key, required this.loan, required this.reminder, required this.onPaid, required this.onDelete});
  final Loan loan;
  final LoanRepaymentReminder reminder;
  final VoidCallback onPaid;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final overdue = reminder.isOverdue;
    final dueToday = reminder.isDueToday;
    final accent = overdue ? kSleekExpense : (dueToday ? kSleekWarning : kSleekAccent);
    final label = overdue ? 'Overdue' : (dueToday ? 'Due today' : 'Upcoming');
    final direction = loan.type == LoanType.given ? 'Expected repayment received' : 'Repayment to pay';
    return ExpressiveCard(
      color: overdue
          ? (Theme.of(context).brightness == Brightness.dark ? const Color(0xFF2A1719) : const Color(0xFFFFF0F0))
          : null,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          iconBubble(context, overdue ? 'warning' : 'reminder', colorToHex(accent), size: 48),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${state.format(reminder.amount)} • $label', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900, color: overdue ? kSleekExpense : null)),
                const SizedBox(height: 3),
                Text('$direction • ${DateFormat('MMM d, yyyy').format(reminder.dueDate)} • ${_formatMinutesAsTime(reminder.reminderTimeMinutes)}', maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700)),
                if (reminder.notes.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(reminder.notes, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
          IconButton(onPressed: onPaid, icon: const Icon(Icons.check_circle_rounded), tooltip: 'Mark paid'),
          IconButton(onPressed: onDelete, icon: const Icon(Icons.delete_outline_rounded), tooltip: 'Delete reminder'),
        ],
      ),
    );
  }
}

class _LoanReminderDraft {
  _LoanReminderDraft({required String amount, required this.dueDate, required this.reminderTimeMinutes, required String notes})
      : id = _uuid.v4(),
        amount = TextEditingController(text: amount),
        notes = TextEditingController(text: notes);

  _LoanReminderDraft.fromReminder(LoanRepaymentReminder reminder)
      : id = reminder.id,
        amount = TextEditingController(text: reminder.amount.toStringAsFixed(2)),
        dueDate = reminder.dueDate,
        reminderTimeMinutes = reminder.reminderTimeMinutes,
        notes = TextEditingController(text: reminder.notes);

  final String id;
  final TextEditingController amount;
  DateTime dueDate;
  int reminderTimeMinutes;
  final TextEditingController notes;

  LoanRepaymentReminder toReminder({required String loanId, required String accountId, required DateTime now}) => LoanRepaymentReminder(
        id: id,
        loanId: loanId,
        accountId: accountId,
        amount: double.tryParse(amount.text) ?? 0,
        dueDate: dueDate,
        reminderTimeMinutes: reminderTimeMinutes,
        notes: notes.text.trim(),
        isPaid: false,
        createdOn: now,
        updatedOn: now,
      );

  void dispose() {
    amount.dispose();
    notes.dispose();
  }
}

class _LoanReminderDraftTile extends StatelessWidget {
  const _LoanReminderDraftTile({required this.draft, required this.index, required this.onChanged, required this.onRemove});
  final _LoanReminderDraft draft;
  final int index;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(.45),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: Text('Partial repayment ${index + 1}', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900))),
              IconButton(onPressed: onRemove, icon: const Icon(Icons.close_rounded)),
            ],
          ),
          const SizedBox(height: 8),
          TextField(controller: draft.amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Partial amount')),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: OutlinedButton.icon(onPressed: () async { final d = await pickDate(context, draft.dueDate); if (d != null) { draft.dueDate = d; onChanged(); } }, icon: const Icon(Icons.event_rounded), label: Text(DateFormat('MMM d, yyyy').format(draft.dueDate)))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(onPressed: () async { final t = await pickTime(context, TimeOfDay(hour: draft.reminderTimeMinutes ~/ 60, minute: draft.reminderTimeMinutes % 60)); if (t != null) { draft.reminderTimeMinutes = t.hour * 60 + t.minute; onChanged(); } }, icon: const Icon(Icons.notifications_active_rounded), label: Text(_formatMinutesAsTime(draft.reminderTimeMinutes)))),
          ]),
          const SizedBox(height: 8),
          TextField(controller: draft.notes, minLines: 1, maxLines: 2, decoration: const InputDecoration(labelText: 'Reminder notes')),
        ],
      ),
    );
  }
}

String _formatMinutesAsTime(int minutes) {
  final hour = (minutes ~/ 60).clamp(0, 23);
  final minute = minutes % 60;
  final suffix = hour >= 12 ? 'PM' : 'AM';
  final displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
  return '$displayHour:${minute.toString().padLeft(2, '0')} $suffix';
}

Future<void> showRepaymentEditor(BuildContext context, Loan loan) async {
  await showKoinlyPopup<void>(
    context,
    maxWidth: 560,
    maxHeight: 640,
    child: RepaymentEditor(loan: loan),
  );
}

class RepaymentEditor extends StatefulWidget {
  const RepaymentEditor({super.key, required this.loan});
  final Loan loan;

  @override
  State<RepaymentEditor> createState() => _RepaymentEditorState();
}

class _RepaymentEditorState extends State<RepaymentEditor> {
  final amount = TextEditingController();
  final notes = TextEditingController();
  String? accountId;
  DateTime paidOn = DateTime.now();

  @override
  void initState() {
    super.initState();
    final state = context.read<AppController>();
    amount.text = widget.loan.remainingAmount.toStringAsFixed(2);
    accountId = widget.loan.accountId.isNotEmpty ? widget.loan.accountId : state.defaultAccountId;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final accountOptions = state.operatingAccounts.isEmpty ? state.accounts : state.operatingAccounts;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 14),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.loan.type == LoanType.given ? 'Repayment received' : 'Repayment paid', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
          const SizedBox(height: 16),
          TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Repayment amount')),
          const SizedBox(height: 12),
          AppleSelectionField(
            label: widget.loan.type == LoanType.given ? 'Receive repayment into account' : 'Pay repayment from account',
            option: accountOptions.where((a) => a.id == accountId).firstOrNull == null ? null : optionFromAccount(accountOptions.where((a) => a.id == accountId).first, state),
            emptyText: 'Choose account',
            onTap: () async {
              final selected = await showAppleWheelSelectionSheet(
                context,
                title: widget.loan.type == LoanType.given ? 'Choose Receiving Account' : 'Choose Payment Account',
                selectedId: accountId,
                options: accountOptions.map((a) => optionFromAccount(a, state)).toList(),
              );
              if (selected != null) setState(() => accountId = selected);
            },
          ),
          const SizedBox(height: 6),
          Text(
            widget.loan.type == LoanType.given
                ? 'Repayment received increases the selected account balance.'
                : 'Repayment paid decreases the selected account balance.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(onPressed: () async { final d = await pickDate(context, paidOn); if (d != null) setState(() => paidOn = d); }, icon: const Icon(Icons.date_range_rounded), label: Text(DateFormat('MMM d, yyyy').format(paidOn))),
          const SizedBox(height: 12),
          TextField(controller: notes, minLines: 1, maxLines: 3, decoration: const InputDecoration(labelText: 'Notes')),
          const SizedBox(height: 18),
          FilledButton(onPressed: () async {
            final value = double.tryParse(amount.text) ?? 0;
            if (value <= 0 || accountId == null) return;
            final repayment = LoanRepayment(id: _uuid.v4(), loanId: widget.loan.id, accountId: accountId!, amount: value, paidOn: paidOn, notes: notes.text.trim(), createdOn: DateTime.now());
            await state.addRepayment(widget.loan, repayment, accountId!);
            if (context.mounted) Navigator.pop(context);
          }, child: const Text('Save repayment')),
        ]),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Settings, export, backup, about
// -----------------------------------------------------------------------------

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    return PageScaffold(
      title: 'Settings',
      child: ResponsiveContent(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        child: Column(
          children: [
            SettingsTile(icon: Icons.palette_rounded, title: 'Theme', subtitle: _themeLabel(state.themePreference), color: '#A6E3A1', onTap: () => showThemeDialog(context)),
            SettingsTile(icon: Icons.payments_rounded, title: 'Currency customization', subtitle: '${state.currencyCode} • ${state.currencyPosition == CurrencyPosition.prefix ? 'Prefix' : 'Suffix'}', color: '#78D8E8', onTap: () => showCurrencySheet(context)),
            SettingsTile(icon: Icons.notifications_active_rounded, title: 'Reminder notification', subtitle: state.reminderEnabled ? 'Daily at ${state.reminderTime.format(context)}' : 'Disabled', color: '#FBC879', onTap: () => showReminderSheet(context)),
            SettingsTile(icon: Icons.lightbulb_rounded, title: 'Savings suggestion profile', subtitle: state.savingsSuggestionProfile.shortLabel, color: '#FFB5D0', onTap: () => showSavingsSuggestionProfileSheet(context)),
            SettingsTile(icon: Icons.cloud_sync_rounded, title: 'Online data sync', subtitle: state.cloudSyncStatusText, color: '#78D8E8', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CloudSyncScreen()))),
            SettingsTile(icon: Icons.filter_alt_rounded, title: 'Default date filter', subtitle: _dateRangeLabel(state.dateRangeType), color: '#B4A5FF', onTap: () => showDateRangeSheet(context)),
            SettingsTile(icon: Icons.ios_share_rounded, title: 'Export', subtitle: 'CSV / PDF reports with current filters', color: '#FFB5D0', onTap: () => showExportSheet(context)),
            SettingsTile(icon: Icons.tune_rounded, title: 'Advanced settings', subtitle: 'Defaults, reorder, app lock, backup', color: '#9AD0F5', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AdvancedSettingsScreen()))),
            SettingsTile(icon: Icons.info_rounded, title: 'About app', subtitle: 'Version, credits, licenses, and links', color: '#86E3CE', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AboutScreen()))),
          ],
        ),
      ),
    );
  }
}


class SettingsTile extends StatelessWidget {
  const SettingsTile({super.key, required this.icon, required this.title, this.subtitle, required this.color, this.onTap});
  final IconData icon;
  final String title;
  final String? subtitle;
  final String color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = colorFromHex(color);
    final hasSubtitle = subtitle != null && subtitle!.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ExpressiveCard(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: hasSubtitle ? 12 : 14),
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: c.withOpacity(.16),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: c.withOpacity(.20)),
            ),
            child: Icon(icon, color: c),
          ),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
          subtitle: hasSubtitle
              ? Text(
                  subtitle!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
                )
              : null,
          trailing: Icon(Icons.chevron_right_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant),
          onTap: onTap,
        ),
      ),
    );
  }
}


class CloudSyncScreen extends StatefulWidget {
  const CloudSyncScreen({super.key});

  @override
  State<CloudSyncScreen> createState() => _CloudSyncScreenState();
}

class _CloudSyncScreenState extends State<CloudSyncScreen> {
  late final TextEditingController _syncIdController;
  late final TextEditingController _pinController;
  bool _obscurePin = true;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppController>();
    _syncIdController = TextEditingController(text: state.cloudSyncId);
    _pinController = TextEditingController(text: state.cloudSyncPin);
  }

  @override
  void dispose() {
    _syncIdController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _saveSettings({bool showStatus = true}) async {
    final state = context.read<AppController>();
    await state.configureCloudSync(
      enabled: true,
      apiBaseUrl: state.cloudSyncApiBaseUrl,
      syncId: _syncIdController.text,
      pin: _pinController.text,
    );
    if (!mounted || !showStatus) return;
    showSnack(context, 'Online sync settings saved.');
  }

  Future<void> _syncNow() async {
    // Sync uploads this device's local data to the configured cloud target.
    await _uploadNow();
  }

  Future<void> _uploadNow() async {
    await _saveSettings(showStatus: false);
    final state = context.read<AppController>();
    await state.syncMainOnlineToCloud(force: true);
    if (!mounted) return;
    _syncIdController.text = state.cloudSyncId;
    _pinController.text = state.cloudSyncPin;
    await _showSyncResult('Local data uploaded to cloud.');
  }

  Future<void> _downloadNow() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Download Data?'),
        content: const Text('This replaces the local SQLite data on this device with the data saved under this Sync ID.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Download')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _saveSettings(showStatus: false);
    final state = context.read<AppController>();
    await state.syncMainOnlineFromCloud();
    if (!mounted) return;
    await _showSyncResult('Cloud data downloaded.');
  }

  Future<void> _showSyncResult(String successMessage) async {
    final state = context.read<AppController>();
    if (state.cloudSyncApprovalRequired) {
      await _showActivationDialog();
      return;
    }
    showSnack(context, state.cloudSyncError == null ? successMessage : state.cloudSyncError!);
  }

  Future<void> _showActivationDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Message admin to activate your online sync.'),
        content: const Text('Your Sync ID is waiting for admin approval. After the admin approves it, press Sync again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          FilledButton.icon(
            onPressed: () async {
              await launchUrl(Uri.parse(kSyncAdminTelegramUrl), mode: LaunchMode.externalApplication);
            },
            icon: const Icon(Icons.send_rounded),
            label: const Text('Telegram'),
          ),
        ],
      ),
    );
  }

  Future<void> _openAdvancedSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SyncDatabaseMethodsScreen()),
    );
    if (!mounted) return;
    final state = context.read<AppController>();
    setState(() {
      _syncIdController.text = state.cloudSyncId;
      _pinController.text = state.cloudSyncPin;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    return PageScaffold(
      title: 'Online data sync',
      actions: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: _openAdvancedSettings,
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(.55),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(.14)),
              ),
              child: const Icon(Icons.more_vert_rounded, size: 30),
            ),
          ),
        ),
      ],
      child: ResponsiveContent(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _syncIdController,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Sync ID',
                hintText: 'Example: siam-main-wallet',
                prefixIcon: Icon(Icons.badge_rounded),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _pinController,
              obscureText: _obscurePin,
              decoration: InputDecoration(
                labelText: 'Sync PIN',
                hintText: 'Minimum 4 characters',
                prefixIcon: const Icon(Icons.password_rounded),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscurePin = !_obscurePin),
                  icon: Icon(_obscurePin ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                ),
              ),
            ),
            if (state.cloudSyncError != null && state.cloudSyncError!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(state.cloudSyncError!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w800)),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: state.cloudSyncBusy || state.syncDatabaseProvider == SyncDatabaseProvider.local ? null : _syncNow,
              icon: state.cloudSyncBusy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_sync_rounded),
              label: const Text('Sync'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: state.cloudSyncBusy || state.syncDatabaseProvider == SyncDatabaseProvider.local ? null : _downloadNow,
              icon: const Icon(Icons.cloud_download_rounded),
              label: const Text('Download Data'),
            ),
            const SizedBox(height: 14),
            Text(
              'Important: Sync uploads this device’s local data. Download Data replaces this device’s local data with the latest cloud data. Automatic sync runs after local changes once a database method is configured. Conflict handling is last-upload-wins.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class SyncDatabaseMethodsScreen extends StatelessWidget {
  const SyncDatabaseMethodsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: 'Hidden Settings',
      child: ResponsiveContent(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExpressiveCard(
              padding: const EdgeInsets.all(18),
              child: InkWell(
                borderRadius: BorderRadius.circular(22),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SyncDatabaseMethodListScreen()),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: kSleekAccent.withOpacity(.15),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Icon(Icons.cloud_sync_rounded, color: kSleekAccent),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        'Select database method',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SyncDatabaseMethodListScreen extends StatelessWidget {
  const SyncDatabaseMethodListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    return PageScaffold(
      title: 'Select database method',
      child: ResponsiveContent(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...userSyncDatabaseProviders.map(
              (provider) => _ProviderChoiceCard(
                provider: provider,
                selected: state.syncDatabaseProvider == provider,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => SyncDatabaseProviderConfigScreen(provider: provider)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SyncDatabaseProviderConfigScreen extends StatefulWidget {
  const SyncDatabaseProviderConfigScreen({super.key, required this.provider});

  final SyncDatabaseProvider provider;

  @override
  State<SyncDatabaseProviderConfigScreen> createState() => _SyncDatabaseProviderConfigScreenState();
}

class _SyncDatabaseProviderConfigScreenState extends State<SyncDatabaseProviderConfigScreen> {
  late final TextEditingController _apiBaseUrlController;
  late final TextEditingController _mongoUrlController;
  late final TextEditingController _mongoDatabaseController;
  late final TextEditingController _mongoCollectionController;
  late final TextEditingController _mongoSyncIdController;
  late final TextEditingController _mongoSyncPinController;
  late final TextEditingController _tursoDatabaseUrlController;
  late final TextEditingController _tursoAuthTokenController;
  bool _obscureMongoUrl = true;
  bool _obscureTursoToken = true;
  bool _testing = false;
  String? _status;

  SyncDatabaseProvider get _provider => widget.provider;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppController>();
    _apiBaseUrlController = TextEditingController(text: state.cloudSyncApiBaseUrl);
    _mongoUrlController = TextEditingController(text: state.syncMongoDbUrl);
    _mongoDatabaseController = TextEditingController(text: state.syncMongoDatabaseName);
    _mongoCollectionController = TextEditingController(text: state.syncMongoCollectionName);
    _mongoSyncIdController = TextEditingController(text: state.syncMongoSyncId);
    _mongoSyncPinController = TextEditingController(text: state.syncMongoSyncPin);
    _tursoDatabaseUrlController = TextEditingController(text: state.syncTursoDatabaseUrl);
    _tursoAuthTokenController = TextEditingController(text: state.syncTursoAuthToken);
  }

  @override
  void dispose() {
    _apiBaseUrlController.dispose();
    _mongoUrlController.dispose();
    _mongoDatabaseController.dispose();
    _mongoCollectionController.dispose();
    _mongoSyncIdController.dispose();
    _mongoSyncPinController.dispose();
    _tursoDatabaseUrlController.dispose();
    _tursoAuthTokenController.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    final state = context.read<AppController>();
    setState(() {
      _testing = true;
      _status = null;
    });
    try {
      await state.testSyncDatabaseConnection(
        provider: _provider,
        apiBaseUrl: _apiBaseUrlController.text,
        mongoDbUrl: _mongoUrlController.text,
        mongoDatabaseName: MongoDbSyncService.defaultDatabaseName,
        mongoCollectionName: MongoDbSyncService.defaultCollectionName,
      );
      if (!mounted) return;
      setState(() => _status = _provider == SyncDatabaseProvider.local ? 'Local Database is ready.' : 'Connection test passed.');
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = redactSyncSecrets(error.toString().replaceFirst('Bad state: ', '').replaceFirst('Exception: ', '')));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _saveProviderSettings({bool showStatus = true, bool closePage = false}) async {
    final state = context.read<AppController>();
    await state.configureSyncDatabase(
      provider: _provider,
      apiBaseUrl: _apiBaseUrlController.text,
      mongoDbUrl: _mongoUrlController.text,
      mongoDatabaseName: MongoDbSyncService.defaultDatabaseName,
      mongoCollectionName: MongoDbSyncService.defaultCollectionName,
      tursoDatabaseUrl: _tursoDatabaseUrlController.text,
      tursoAuthToken: _tursoAuthTokenController.text,
    );
    if (!mounted) return;
    if (showStatus) showSnack(context, '${syncDatabaseProviderLabel(_provider)} settings saved.');
    if (closePage) Navigator.pop(context);
  }

  Future<void> _save() async {
    await _saveProviderSettings(closePage: true);
  }

  Future<void> _syncNow() async {
    // Sync uploads this device's local data to the selected database provider.
    await _uploadNow();
  }

  Future<void> _uploadNow() async {
    await _saveProviderSettings(showStatus: false);
    final state = context.read<AppController>();
    await state.syncToCloud(force: true);
    if (!mounted) return;
    await _showSyncResult('Local data uploaded to cloud.');
  }

  Future<void> _downloadNow() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Download Data?'),
        content: Text(_provider == SyncDatabaseProvider.mongoDb
            ? 'This replaces this device’s local data with the latest snapshot from your MongoDB database.'
            : 'This replaces this device’s local data with the latest cloud snapshot for the current Sync ID.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Download')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _saveProviderSettings(showStatus: false);
    final state = context.read<AppController>();
    await state.syncFromCloud();
    if (!mounted) return;
    await _showSyncResult('Cloud data downloaded.');
  }

  Future<void> _showSyncResult(String successMessage) async {
    final state = context.read<AppController>();
    if (state.cloudSyncApprovalRequired) {
      await _showActivationDialog();
      return;
    }
    showSnack(context, state.cloudSyncError == null ? successMessage : state.cloudSyncError!);
  }

  Future<void> _showActivationDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Message admin to activate your online sync.'),
        content: const Text('Your Sync ID is waiting for admin approval. After the admin approves it, press Sync again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          FilledButton.icon(
            onPressed: () async {
              await launchUrl(Uri.parse(kSyncAdminTelegramUrl), mode: LaunchMode.externalApplication);
            },
            icon: const Icon(Icons.send_rounded),
            label: const Text('Telegram'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final providerLabel = syncDatabaseProviderLabel(_provider);
    return PageScaffold(
      title: providerLabel,
      subtitle: 'Sync method setup',
      child: ResponsiveContent(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExpressiveCard(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: kSleekAccent.withOpacity(.15),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(syncDatabaseProviderIcon(_provider), color: kSleekAccent),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(providerLabel, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
                        const SizedBox(height: 4),
                        Text(syncDatabaseProviderSubtitle(_provider), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _providerFields(),
            if (_status != null && _status!.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(_status!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekAccent, fontWeight: FontWeight.w800)),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _testing || state.cloudSyncBusy ? null : _testConnection,
                    icon: _testing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.network_check_rounded),
                    label: const Text('Test'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _testing || state.cloudSyncBusy ? null : _save,
                    icon: const Icon(Icons.save_rounded),
                    label: const Text('Save'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _ProviderSyncActions(
              provider: _provider,
              busy: state.cloudSyncBusy,
              onSync: _syncNow,
              onUpload: _downloadNow,
            ),
          ],
        ),
      ),
    );
  }


  Widget _workerBackedProviderFields(SyncDatabaseProvider provider) {
    final label = syncDatabaseProviderLabel(provider);
    return Column(
      key: ValueKey('${enumName(provider)}-method-page'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _apiBaseUrlController,
          decoration: InputDecoration(
            labelText: '$label API URL',
            hintText: 'https://your-koinly-sync-worker.workers.dev',
            prefixIcon: Icon(syncDatabaseProviderIcon(provider)),
          ),
        ),
        const SizedBox(height: 10),
        ExpressiveCard(
          padding: const EdgeInsets.all(16),
          child: Text(
            '$label uses your Koinly sync backend API. Configure that backend to store snapshots in $label, then paste the API URL here. Sync ID and Sync PIN stay on this database method page.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }

  Widget _hiddenTursoNotice() {
    return ExpressiveCard(
      key: const ValueKey('turso-hidden'),
      padding: const EdgeInsets.all(16),
      child: const Text('Turso Database is hidden for users for now. Choose another database method.'),
    );
  }


  Widget _providerFields() {
    switch (_provider) {
      case SyncDatabaseProvider.local:
        return ExpressiveCard(
          key: const ValueKey('local-method-page'),
          padding: const EdgeInsets.all(16),
          child: const Text('Local Database mode keeps everything in this device SQLite database. Online sync stays disabled and no credentials are required.'),
        );
      case SyncDatabaseProvider.mongoDb:
        return Column(
          key: const ValueKey('mongodb-method-page'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _mongoUrlController,
              obscureText: _obscureMongoUrl,
              decoration: InputDecoration(
                labelText: 'MongoDB URL',
                hintText: 'mongodb+srv://user:password@cluster.mongodb.net/koinly',
                prefixIcon: const Icon(Icons.link_rounded),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscureMongoUrl = !_obscureMongoUrl),
                  icon: Icon(_obscureMongoUrl ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Use your own MongoDB database. Koinly stores one latest app snapshot in its internal collection.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
            ),
          ],
        );
      case SyncDatabaseProvider.turso:
        return _hiddenTursoNotice();
      case SyncDatabaseProvider.cloudflareD1:
      case SyncDatabaseProvider.supabase:
      case SyncDatabaseProvider.neonPostgres:
      case SyncDatabaseProvider.firebaseFirestore:
        return _workerBackedProviderFields(_provider);
    }
  }
}

class _ProviderSyncActions extends StatelessWidget {
  const _ProviderSyncActions({
    required this.provider,
    required this.busy,
    required this.onSync,
    required this.onUpload,
  });

  final SyncDatabaseProvider provider;
  final bool busy;
  final VoidCallback onSync;
  final VoidCallback onUpload;

  @override
  Widget build(BuildContext context) {
    final isCloudProvider = provider != SyncDatabaseProvider.local && provider != SyncDatabaseProvider.turso;
    final disabled = busy || !isCloudProvider;
    return ExpressiveCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: kSleekAccent.withOpacity(.15),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(Icons.sync_rounded, color: kSleekAccent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Sync actions', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: disabled ? null : onSync,
            icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.sync_rounded),
            label: const Text('Sync'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: disabled ? null : onUpload,
            icon: const Icon(Icons.cloud_download_rounded),
            label: const Text('Download Data'),
          ),
        ],
      ),
    );
  }
}

class SyncAdvancedDatabasePopup extends StatefulWidget {
  const SyncAdvancedDatabasePopup({super.key});

  @override
  State<SyncAdvancedDatabasePopup> createState() => _SyncAdvancedDatabasePopupState();
}

class _SyncAdvancedDatabasePopupState extends State<SyncAdvancedDatabasePopup> {
  late SyncDatabaseProvider _provider;
  late final TextEditingController _apiBaseUrlController;
  late final TextEditingController _mongoUrlController;
  late final TextEditingController _mongoDatabaseController;
  late final TextEditingController _mongoCollectionController;
  late final TextEditingController _tursoDatabaseUrlController;
  late final TextEditingController _tursoAuthTokenController;
  bool _obscureMongoUrl = true;
  bool _obscureTursoToken = true;
  bool _testing = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppController>();
    _provider = state.syncDatabaseProvider == SyncDatabaseProvider.turso ? SyncDatabaseProvider.local : state.syncDatabaseProvider;
    _apiBaseUrlController = TextEditingController(text: state.cloudSyncApiBaseUrl);
    _mongoUrlController = TextEditingController(text: state.syncMongoDbUrl);
    _mongoDatabaseController = TextEditingController(text: state.syncMongoDatabaseName);
    _mongoCollectionController = TextEditingController(text: state.syncMongoCollectionName);
    _tursoDatabaseUrlController = TextEditingController(text: state.syncTursoDatabaseUrl);
    _tursoAuthTokenController = TextEditingController(text: state.syncTursoAuthToken);
  }

  @override
  void dispose() {
    _apiBaseUrlController.dispose();
    _mongoUrlController.dispose();
    _mongoDatabaseController.dispose();
    _mongoCollectionController.dispose();
    _tursoDatabaseUrlController.dispose();
    _tursoAuthTokenController.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    final state = context.read<AppController>();
    setState(() {
      _testing = true;
      _status = null;
    });
    try {
      await state.testSyncDatabaseConnection(
        provider: _provider,
        apiBaseUrl: _apiBaseUrlController.text,
        mongoDbUrl: _mongoUrlController.text,
        mongoDatabaseName: MongoDbSyncService.defaultDatabaseName,
        mongoCollectionName: MongoDbSyncService.defaultCollectionName,
      );
      if (!mounted) return;
      setState(() => _status = _provider == SyncDatabaseProvider.local ? 'Local Database is ready.' : 'Connection test passed.');
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = redactSyncSecrets(error.toString().replaceFirst('Bad state: ', '').replaceFirst('Exception: ', '')));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    final state = context.read<AppController>();
    await state.configureSyncDatabase(
      provider: _provider,
      apiBaseUrl: _apiBaseUrlController.text,
      mongoDbUrl: _mongoUrlController.text,
      mongoDatabaseName: MongoDbSyncService.defaultDatabaseName,
      mongoCollectionName: MongoDbSyncService.defaultCollectionName,
      tursoDatabaseUrl: _tursoDatabaseUrlController.text,
      tursoAuthToken: _tursoAuthTokenController.text,
    );
    if (!mounted) return;
    showSnack(context, 'Advanced sync database settings saved.');
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: kSleekAccent.withOpacity(.14), borderRadius: BorderRadius.circular(16)),
                  child: const Icon(Icons.tune_rounded, color: kSleekAccent),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text('Advanced sync database', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900))),
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded)),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              'Choose where Koinly stores online sync snapshots. Credentials are saved with platform secure storage and are not included in backups.',
              style: theme.textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            ...userSyncDatabaseProviders.map((provider) => _ProviderChoiceCard(
                  provider: provider,
                  selected: _provider == provider,
                  onTap: () => setState(() => _provider = provider),
                )),
            const SizedBox(height: 10),
            AnimatedSwitcher(
              duration: AppMotion.medium,
              switchInCurve: AppMotion.emphasized,
              switchOutCurve: AppMotion.emphasizedAccelerate,
              child: _providerFields(),
            ),
            if (_status != null && _status!.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(_status!, style: theme.textTheme.bodySmall?.copyWith(color: kSleekAccent, fontWeight: FontWeight.w800)),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _testing ? null : _testConnection,
                    icon: _testing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.network_check_rounded),
                    label: const Text('Test Connection'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _testing ? null : _save,
                    icon: const Icon(Icons.save_rounded),
                    label: const Text('Save'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }


  Widget _workerBackedProviderFields(SyncDatabaseProvider provider) {
    final label = syncDatabaseProviderLabel(provider);
    return Column(
      key: ValueKey('${enumName(provider)}-advanced'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _apiBaseUrlController,
          decoration: InputDecoration(
            labelText: '$label API URL',
            hintText: 'https://your-koinly-sync-worker.workers.dev',
            prefixIcon: Icon(syncDatabaseProviderIcon(provider)),
          ),
        ),
        const SizedBox(height: 10),
        ExpressiveCard(
          padding: const EdgeInsets.all(16),
          child: Text(
            '$label uses your Koinly sync backend API. Configure that backend to store snapshots in $label, then paste the API URL here. Sync ID and Sync PIN stay on this database method page.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }

  Widget _hiddenTursoNotice() {
    return ExpressiveCard(
      key: const ValueKey('turso-hidden-advanced'),
      padding: const EdgeInsets.all(16),
      child: const Text('Turso Database is hidden for users for now. Choose another database method.'),
    );
  }

  Widget _providerFields() {
    switch (_provider) {
      case SyncDatabaseProvider.local:
        return ExpressiveCard(
          key: const ValueKey('local'),
          padding: const EdgeInsets.all(16),
          child: const Text('Local Database mode keeps everything in this device SQLite database. Online sync stays disabled and no credentials are required.'),
        );
      case SyncDatabaseProvider.mongoDb:
        return Column(
          key: const ValueKey('mongodb'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _mongoUrlController,
              obscureText: _obscureMongoUrl,
              decoration: InputDecoration(
                labelText: 'MongoDB URL',
                hintText: 'mongodb+srv://user:password@cluster.mongodb.net/koinly',
                prefixIcon: const Icon(Icons.link_rounded),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscureMongoUrl = !_obscureMongoUrl),
                  icon: Icon(_obscureMongoUrl ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Use your own MongoDB database. Koinly stores one latest app snapshot in its internal collection.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
            ),
          ],
        );
      case SyncDatabaseProvider.turso:
        return _hiddenTursoNotice();
      case SyncDatabaseProvider.cloudflareD1:
      case SyncDatabaseProvider.supabase:
      case SyncDatabaseProvider.neonPostgres:
      case SyncDatabaseProvider.firebaseFirestore:
        return _workerBackedProviderFields(_provider);
    }
  }
}

class _ProviderChoiceCard extends StatelessWidget {
  const _ProviderChoiceCard({required this.provider, required this.selected, required this.onTap});

  final SyncDatabaseProvider provider;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.emphasized,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: selected ? kSleekAccent.withOpacity(.16) : scheme.surfaceContainerHighest.withOpacity(.34),
            borderRadius: BorderRadius.circular(selected ? 28 : 22),
            border: Border.all(color: selected ? kSleekAccent.withOpacity(.75) : scheme.outline.withOpacity(.18), width: selected ? 1.5 : 1),
          ),
          child: Row(
            children: [
              Icon(syncDatabaseProviderIcon(provider), color: selected ? kSleekAccent : scheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(syncDatabaseProviderLabel(provider), style: const TextStyle(fontWeight: FontWeight.w900)),
                    const SizedBox(height: 3),
                    Text(syncDatabaseProviderSubtitle(provider), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
              Icon(selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, color: selected ? kSleekAccent : scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

extension _BubbleOverride on Widget {
  Widget withIcon(IconData icon) => Builder(builder: (context) {
        return Stack(alignment: Alignment.center, children: [this, Icon(icon, color: colorFromHex('#FFFFFF').withOpacity(0), size: 0)]);
      });
}

Future<void> showThemeDialog(BuildContext context) async {
  final state = context.read<AppController>();
  final selectedId = await showAppleWheelSelectionSheet(
    context,
    title: 'Choose Theme',
    selectedId: enumName(state.themePreference),
    options: ThemePreference.values.map(optionFromThemePreference).toList(),
  );
  if (selectedId == null) return;
  final selected = ThemePreference.values.firstWhere(
    (theme) => enumName(theme) == selectedId,
    orElse: () => state.themePreference,
  );
  await state.saveTheme(selected);
}

SelectionOption optionFromThemePreference(ThemePreference theme) {
  switch (theme) {
    case ThemePreference.system:
      return const SelectionOption(
        id: 'system',
        title: 'System Default',
        subtitle: 'Follow device setting',
        iconName: 'theme_system',
        iconColor: '#A6E3A1',
      );
    case ThemePreference.light:
      return const SelectionOption(
        id: 'light',
        title: 'Light',
        subtitle: 'Bright interface',
        iconName: 'theme_light',
        iconColor: '#FBC879',
      );
    case ThemePreference.dark:
      return const SelectionOption(
        id: 'dark',
        title: 'Dark',
        subtitle: 'Low-light interface',
        iconName: 'theme_dark',
        iconColor: '#B4A5FF',
      );
    case ThemePreference.batterySaver:
      return const SelectionOption(
        id: 'batterySaver',
        title: 'Battery Saver / System',
        subtitle: 'Use system behavior',
        iconName: 'theme_battery',
        iconColor: '#78D8E8',
      );
  }
}

String _themeLabel(ThemePreference t) {
  switch (t) {
    case ThemePreference.system: return 'System Default';
    case ThemePreference.light: return 'Light';
    case ThemePreference.dark: return 'Dark';
    case ThemePreference.batterySaver: return 'Battery Saver / System';
  }
}

String _dateRangeLabel(DateRangeType type) {
  switch (type) {
    case DateRangeType.today: return 'Today';
    case DateRangeType.thisWeek: return 'This Week';
    case DateRangeType.thisMonth: return 'This Month';
    case DateRangeType.thisYear: return 'This Year';
    case DateRangeType.allTime: return 'All Time';
    case DateRangeType.custom: return 'Custom';
  }
}

void showCurrencySheet(BuildContext context) {
  final state = context.read<AppController>();
  showKoinlyPopup<void>(
    context,
    maxWidth: 560,
    maxHeight: 720,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 14),
      child: SingleChildScrollView(
        child: CurrencyForm(initialSymbol: state.currencySymbol, initialCode: state.currencyCode, initialPosition: state.currencyPosition, initialSeparators: state.useSeparators, closeAfterSave: true),
      ),
    ),
  );
}

class CurrencyForm extends StatefulWidget {
  const CurrencyForm({super.key, required this.initialSymbol, required this.initialCode, required this.initialPosition, required this.initialSeparators, this.closeAfterSave = false});
  final String initialSymbol;
  final String initialCode;
  final CurrencyPosition initialPosition;
  final bool initialSeparators;
  final bool closeAfterSave;

  @override
  State<CurrencyForm> createState() => _CurrencyFormState();
}

class _CurrencyFormState extends State<CurrencyForm> {
  late TextEditingController symbol;
  late TextEditingController code;
  late CurrencyPosition position;
  late bool separators;
  static const countries = <List<String>>[
    ["Afghanistan", "؋", "AFN"],
    ["Albania", "L", "ALL"],
    ["Algeria", "دج", "DZD"],
    ["Angola", "Kz", "AOA"],
    ["Argentina", "\$", "ARS"],
    ["Armenia", "֏", "AMD"],
    ["Aruba", "ƒ", "AWG"],
    ["Australia", "\$", "AUD"],
    ["Azerbaijan", "₼", "AZN"],
    ["Bahamas", "\$", "BSD"],
    ["Bahrain", ".د.ب", "BHD"],
    ["Bangladesh", "৳", "BDT"],
    ["Barbados", "\$", "BBD"],
    ["Belarus", "Br", "BYN"],
    ["Belize", "\$", "BZD"],
    ["Bermuda", "\$", "BMD"],
    ["Bhutan", "Nu.", "BTN"],
    ["Bolivia", "Bs.", "BOB"],
    ["Bosnia and Herzegovina", "KM", "BAM"],
    ["Botswana", "P", "BWP"],
    ["Brazil", "R\$", "BRL"],
    ["Brunei", "\$", "BND"],
    ["Bulgaria", "лв", "BGN"],
    ["Burundi", "FBu", "BIF"],
    ["Cambodia", "៛", "KHR"],
    ["Canada", "\$", "CAD"],
    ["Cape Verde", "\$", "CVE"],
    ["Cayman Islands", "\$", "KYD"],
    ["Chile", "\$", "CLP"],
    ["China", "¥", "CNY"],
    ["Colombia", "\$", "COP"],
    ["Comoros", "CF", "KMF"],
    ["Costa Rica", "₡", "CRC"],
    ["Croatia", "€", "EUR"],
    ["Cuba", "\$", "CUP"],
    ["Czech Republic", "Kč", "CZK"],
    ["Denmark", "kr", "DKK"],
    ["Djibouti", "Fdj", "DJF"],
    ["Dominican Republic", "RD\$", "DOP"],
    ["DR Congo", "FC", "CDF"],
    ["East Caribbean", "EC\$", "XCD"],
    ["Egypt", "E£", "EGP"],
    ["El Salvador", "\$", "USD"],
    ["Eritrea", "Nfk", "ERN"],
    ["Eswatini", "E", "SZL"],
    ["Ethiopia", "Br", "ETB"],
    ["Euro Area", "€", "EUR"],
    ["Falkland Islands", "£", "FKP"],
    ["Fiji", "\$", "FJD"],
    ["Gambia", "D", "GMD"],
    ["Georgia", "₾", "GEL"],
    ["Ghana", "₵", "GHS"],
    ["Gibraltar", "£", "GIP"],
    ["Guatemala", "Q", "GTQ"],
    ["Guernsey", "£", "GGP"],
    ["Guinea", "FG", "GNF"],
    ["Guyana", "\$", "GYD"],
    ["Haiti", "G", "HTG"],
    ["Honduras", "L", "HNL"],
    ["Hong Kong", "\$", "HKD"],
    ["Hungary", "Ft", "HUF"],
    ["Iceland", "kr", "ISK"],
    ["India", "₹", "INR"],
    ["Indonesia", "Rp", "IDR"],
    ["Iran", "﷼", "IRR"],
    ["Iraq", "ع.د", "IQD"],
    ["Isle of Man", "£", "IMP"],
    ["Israel", "₪", "ILS"],
    ["Jamaica", "J\$", "JMD"],
    ["Japan", "¥", "JPY"],
    ["Jersey", "£", "JEP"],
    ["Jordan", "د.ا", "JOD"],
    ["Kazakhstan", "₸", "KZT"],
    ["Kenya", "KSh", "KES"],
    ["Kuwait", "د.ك", "KWD"],
    ["Kyrgyzstan", "с", "KGS"],
    ["Laos", "₭", "LAK"],
    ["Lebanon", "ل.ل", "LBP"],
    ["Lesotho", "L", "LSL"],
    ["Liberia", "\$", "LRD"],
    ["Libya", "ل.د", "LYD"],
    ["Macau", "MOP\$", "MOP"],
    ["Madagascar", "Ar", "MGA"],
    ["Malawi", "MK", "MWK"],
    ["Malaysia", "RM", "MYR"],
    ["Maldives", "Rf", "MVR"],
    ["Mauritania", "UM", "MRU"],
    ["Mauritius", "₨", "MUR"],
    ["Mexico", "\$", "MXN"],
    ["Moldova", "L", "MDL"],
    ["Mongolia", "₮", "MNT"],
    ["Morocco", "د.م.", "MAD"],
    ["Mozambique", "MT", "MZN"],
    ["Myanmar", "K", "MMK"],
    ["Namibia", "\$", "NAD"],
    ["Nepal", "₨", "NPR"],
    ["Netherlands Antilles", "ƒ", "ANG"],
    ["New Zealand", "\$", "NZD"],
    ["Nicaragua", "C\$", "NIO"],
    ["Nigeria", "₦", "NGN"],
    ["North Macedonia", "ден", "MKD"],
    ["Norway", "kr", "NOK"],
    ["Oman", "ر.ع.", "OMR"],
    ["Pakistan", "₨", "PKR"],
    ["Panama", "B/.", "PAB"],
    ["Papua New Guinea", "K", "PGK"],
    ["Paraguay", "₲", "PYG"],
    ["Peru", "S/", "PEN"],
    ["Philippines", "₱", "PHP"],
    ["Poland", "zł", "PLN"],
    ["Qatar", "ر.ق", "QAR"],
    ["Romania", "lei", "RON"],
    ["Russia", "₽", "RUB"],
    ["Rwanda", "FRw", "RWF"],
    ["Saint Helena", "£", "SHP"],
    ["Samoa", "T", "WST"],
    ["Saudi Arabia", "﷼", "SAR"],
    ["Serbia", "дин", "RSD"],
    ["Seychelles", "₨", "SCR"],
    ["Sierra Leone", "Le", "SLE"],
    ["Singapore", "\$", "SGD"],
    ["Solomon Islands", "\$", "SBD"],
    ["Somalia", "Sh", "SOS"],
    ["South Africa", "R", "ZAR"],
    ["South Korea", "₩", "KRW"],
    ["South Sudan", "£", "SSP"],
    ["Sri Lanka", "₨", "LKR"],
    ["Sudan", "ج.س.", "SDG"],
    ["Suriname", "\$", "SRD"],
    ["Sweden", "kr", "SEK"],
    ["Switzerland", "CHF", "CHF"],
    ["Syria", "£", "SYP"],
    ["São Tomé and Príncipe", "Db", "STN"],
    ["Taiwan", "NT\$", "TWD"],
    ["Tajikistan", "ЅМ", "TJS"],
    ["Tanzania", "TSh", "TZS"],
    ["Thailand", "฿", "THB"],
    ["Tonga", "T\$", "TOP"],
    ["Trinidad and Tobago", "TT\$", "TTD"],
    ["Tunisia", "د.ت", "TND"],
    ["Turkey", "₺", "TRY"],
    ["Turkmenistan", "m", "TMT"],
    ["Uganda", "USh", "UGX"],
    ["Ukraine", "₴", "UAH"],
    ["United Arab Emirates", "د.إ", "AED"],
    ["United Kingdom", "£", "GBP"],
    ["United States", "\$", "USD"],
    ["Uruguay", "\$U", "UYU"],
    ["Uzbekistan", "soʻm", "UZS"],
    ["Vanuatu", "VT", "VUV"],
    ["Venezuela", "Bs.", "VES"],
    ["Vietnam", "₫", "VND"],
    ["Yemen", "﷼", "YER"],
    ["Zambia", "ZK", "ZMW"],
    ["Zimbabwe", "\$", "ZWL"],
  ];

  @override
  void initState() {
    super.initState();
    symbol = TextEditingController(text: widget.initialSymbol);
    code = TextEditingController(text: widget.initialCode);
    position = widget.initialPosition;
    separators = widget.initialSeparators;
    symbol.addListener(_persistCurrency);
    code.addListener(_persistCurrency);
  }

  @override
  void dispose() {
    symbol.removeListener(_persistCurrency);
    code.removeListener(_persistCurrency);
    symbol.dispose();
    code.dispose();
    super.dispose();
  }

  void _persistCurrency() {
    if (!mounted) return;
    context.read<AppController>().saveCurrency(
      symbol: symbol.text.trim().isEmpty ? '৳' : symbol.text.trim(),
      code: code.text.trim().isEmpty ? 'BDT' : code.text.trim().toUpperCase(),
      position: position,
      separators: separators,
    );
  }

  List<String> get _selectedCurrency {
    final exact = countries.where((c) => c[1] == symbol.text && c[2] == code.text).toList();
    if (exact.isNotEmpty) return exact.first;
    final byCode = countries.where((c) => c[2] == code.text).toList();
    if (byCode.isNotEmpty) return byCode.first;
    return ['Custom currency', symbol.text.trim().isEmpty ? '৳' : symbol.text.trim(), code.text.trim().isEmpty ? 'BDT' : code.text.trim()];
  }

  Future<void> _openCurrencyPicker() async {
    final selected = await showCurrencyWheelPickerSheet(
      context,
      countries: countries,
      selectedCode: code.text,
      selectedSymbol: symbol.text,
    );
    if (selected == null || !mounted) return;
    setState(() {
      symbol.text = selected[1];
      code.text = selected[2];
    });
    _persistCurrency();
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedCurrency;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.closeAfterSave) ...[
          Text('Currency customization', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
          const SizedBox(height: 14),
        ],
        CurrencyCustomizationButton(
          country: selected[0],
          symbol: selected[1],
          code: selected[2],
          onTap: _openCurrencyPicker,
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: TextField(controller: symbol, decoration: const InputDecoration(labelText: 'Symbol'))),
          const SizedBox(width: 10),
          Expanded(child: TextField(controller: code, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Code'))),
        ]),
        const SizedBox(height: 12),
        SleekPillSelector<CurrencyPosition>(
          options: const [
            SleekPillOption(value: CurrencyPosition.prefix, label: 'Prefix'),
            SleekPillOption(value: CurrencyPosition.suffix, label: 'Suffix'),
          ],
          selected: position,
          onChanged: (v) {
            setState(() => position = v);
            _persistCurrency();
          },
        ),
        SwitchListTile(
          value: separators,
          onChanged: (v) {
            setState(() => separators = v);
            _persistCurrency();
          },
          title: const Text('Use comma separator'),
          contentPadding: EdgeInsets.zero,
        ),
      ],
    );
  }
}

class CurrencyCustomizationButton extends StatelessWidget {
  const CurrencyCustomizationButton({
    super.key,
    required this.country,
    required this.symbol,
    required this.code,
    required this.onTap,
  });

  final String country;
  final String symbol;
  final String code;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withOpacity(.52),
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(.28), width: .9),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: kSleekAccent.withOpacity(.16),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: kSleekAccent.withOpacity(.24)),
                ),
                child: const Icon(Icons.payments_rounded, color: kSleekAccent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Currency customization', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
                    const SizedBox(height: 3),
                    Text(
                      '$country • $symbol • $code',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

Future<List<String>?> showCurrencyWheelPickerSheet(
  BuildContext context, {
  required List<List<String>> countries,
  required String selectedCode,
  required String selectedSymbol,
}) async {
  var search = '';
  var selectedIndex = countries.indexWhere((c) => c[2] == selectedCode && c[1] == selectedSymbol);
  if (selectedIndex < 0) selectedIndex = countries.indexWhere((c) => c[2] == selectedCode);
  if (selectedIndex < 0) selectedIndex = 0;

  List<List<String>> filteredCountries() {
    final query = search.trim().toLowerCase();
    final filtered = query.isEmpty
        ? countries.toList()
        : countries.where((c) => c.join(' ').toLowerCase().contains(query)).toList();
    filtered.sort((a, b) => a[0].compareTo(b[0]));
    return filtered;
  }

  return showKoinlyPopup<List<String>>(
    context,
    maxWidth: 560,
    maxHeight: 660,
    child: StatefulBuilder(
      builder: (dialogContext, setModalState) {
        final filtered = filteredCountries();
        if (filtered.isNotEmpty && selectedIndex >= filtered.length) selectedIndex = 0;
        final safeIndex = filtered.isEmpty ? 0 : (selectedIndex < 0 ? 0 : selectedIndex >= filtered.length ? filtered.length - 1 : selectedIndex);
        final selected = filtered.isEmpty ? null : filtered[safeIndex];
        final dark = Theme.of(dialogContext).brightness == Brightness.dark;
        final innerColor = dark ? const Color(0xFF0B1417) : const Color(0xFFF5FAFB);
        final innerBorderColor = dark ? const Color(0xFF1F3036) : const Color(0xFFDCE8EB);
        final handleColor = dark ? const Color(0xFF43545B) : const Color(0xFFB7C8CE);

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(color: handleColor, borderRadius: BorderRadius.circular(999)),
              ),
              const SizedBox(height: 18),
              Text('Choose currency', textAlign: TextAlign.center, style: Theme.of(dialogContext).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900)),
              const SizedBox(height: 12),
              TextField(
                autofocus: false,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search_rounded),
                  hintText: 'Search countries or currency code',
                ),
                onChanged: (value) => setModalState(() {
                  search = value;
                  selectedIndex = 0;
                }),
              ),
              const SizedBox(height: 12),
              Container(
                height: 252,
                decoration: BoxDecoration(
                  color: innerColor,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: innerBorderColor),
                ),
                child: filtered.isEmpty
                    ? Center(
                        child: Text(
                          'No currency found',
                          style: Theme.of(dialogContext).textTheme.bodyLarge?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
                        ),
                      )
                    : Stack(
                        alignment: Alignment.center,
                        children: [
                          IgnorePointer(
                            child: Container(
                              height: 72,
                              margin: const EdgeInsets.symmetric(horizontal: 12),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(18),
                                color: kSleekAccent.withOpacity(.10),
                                border: Border.all(color: kSleekAccent.withOpacity(.28), width: 1.1),
                              ),
                            ),
                          ),
                          ListWheelScrollView.useDelegate(
                            key: ValueKey(search),
                            itemExtent: 72,
                            diameterRatio: 100000,
                            perspective: 0.0001,
                            squeeze: 1.0,
                            physics: const FixedExtentScrollPhysics(),
                            overAndUnderCenterOpacity: .34,
                            onSelectedItemChanged: (index) => setModalState(() => selectedIndex = index),
                            childDelegate: ListWheelChildBuilderDelegate(
                              childCount: filtered.length,
                              builder: (context, index) {
                                final c = filtered[index];
                                final isSelected = index == safeIndex;
                                return _CurrencyWheelRow(country: c, selected: isSelected);
                              },
                            ),
                          ),
                        ],
                      ),
              ),
              const SizedBox(height: 12),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: selected == null
                    ? const SizedBox(height: 40)
                    : Row(
                        key: ValueKey('${selected[0]}-${selected[2]}'),
                        children: [
                          _CurrencySymbolBubble(symbol: selected[1], selected: true),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              selected[0],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(dialogContext).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900),
                            ),
                          ),
                          Text(
                            '${selected[1]} • ${selected[2]}',
                            style: Theme.of(dialogContext).textTheme.labelMedium?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w800),
                          ),
                        ],
                      ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: selected == null ? null : () => Navigator.pop(dialogContext, selected),
                      child: const Text('Done'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    ),
  );
}

class _CurrencyWheelRow extends StatelessWidget {
  const _CurrencyWheelRow({required this.country, required this.selected});

  final List<String> country;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.center,
      child: SizedBox(
        height: 72,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _CurrencySymbolBubble(symbol: country[1], selected: selected),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      country[0],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: selected ? Theme.of(context).colorScheme.onSurface : Theme.of(context).colorScheme.onSurface.withOpacity(.72),
                          ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${country[1]} • ${country[2]}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: selected ? kSleekMuted : kSleekMuted.withOpacity(.72),
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CurrencySymbolBubble extends StatelessWidget {
  const _CurrencySymbolBubble({required this.symbol, required this.selected});

  final String symbol;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: selected ? 46 : 40,
      height: selected ? 46 : 40,
      decoration: BoxDecoration(
        color: kSleekAccent.withOpacity(selected ? .20 : .12),
        borderRadius: BorderRadius.circular(selected ? 16 : 14),
        border: Border.all(color: kSleekAccent.withOpacity(selected ? .36 : .18), width: selected ? 1.3 : 1),
      ),
      alignment: Alignment.center,
      child: Text(
        symbol,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: kSleekAccent,
              fontWeight: FontWeight.w900,
            ),
      ),
    );
  }
}


void showReminderSheet(BuildContext context) {
  showKoinlyPopup<void>(context, maxWidth: 520, maxHeight: 520, child: const ReminderSheet());
}

class ReminderSheet extends StatefulWidget {
  const ReminderSheet({super.key});

  @override
  State<ReminderSheet> createState() => _ReminderSheetState();
}

class _ReminderSheetState extends State<ReminderSheet> {
  late bool enabled;
  late TimeOfDay time;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppController>();
    enabled = state.reminderEnabled;
    time = state.reminderTime;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppController>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Daily reminder', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
        SwitchListTile(value: enabled, onChanged: (v) => setState(() => enabled = v), title: const Text('Enable reminder'), subtitle: const Text('Notification text: “Don’t forget to record your expenses”')),
        OutlinedButton.icon(onPressed: () async { final t = await pickTime(context, time); if (t != null) setState(() => time = t); }, icon: const Icon(Icons.schedule_rounded), label: Text(time.format(context))),
        const SizedBox(height: 12),
        FilledButton(onPressed: () async { await state.setReminder(enabled, time); if (context.mounted) Navigator.pop(context); }, child: const Text('Save reminder')),
      ]),
    );
  }
}

void showExportSheet(BuildContext context) {
  showKoinlyPopup<void>(context, maxWidth: 520, maxHeight: 520, child: const ExportSheet());
}

class ExportSheet extends StatelessWidget {
  const ExportSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final txs = state.filteredTransactions();
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Export report', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
        const SizedBox(height: 8),
        Text('${txs.length} filtered transactions will be exported with summary data.'),
        const SizedBox(height: 14),
        FilledButton.icon(onPressed: () => ExportService.exportCsv(state, txs), icon: const Icon(Icons.table_chart_rounded), label: const Text('Export CSV')),
        const SizedBox(height: 10),
        FilledButton.tonalIcon(onPressed: () => ExportService.exportPdf(state, txs), icon: const Icon(Icons.picture_as_pdf_rounded), label: const Text('Export PDF')),
      ]),
    );
  }
}

class AdvancedSettingsScreen extends StatelessWidget {
  const AdvancedSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    return PageScaffold(
      title: 'Advanced settings',
      child: ResponsiveContent(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        child: Column(children: [
          SettingsTile(icon: Icons.account_balance_wallet_rounded, title: 'Default account', subtitle: state.defaultAccountId == null ? 'Not selected' : state.accountOf(state.defaultAccountId!)?.name ?? 'Unknown', color: '#78D8E8', onTap: () => showDefaultSelection(context, 'account')),
          SettingsTile(icon: Icons.north_east_rounded, title: 'Default expense category', subtitle: state.defaultExpenseCategoryId == null ? 'Not selected' : state.categoryOf(state.defaultExpenseCategoryId!)?.name ?? 'Unknown', color: '#FF9F9F', onTap: () => showDefaultSelection(context, 'expense')),
          SettingsTile(icon: Icons.south_west_rounded, title: 'Default income category', subtitle: state.defaultIncomeCategoryId == null ? 'Not selected' : state.categoryOf(state.defaultIncomeCategoryId!)?.name ?? 'Unknown', color: '#A6E3A1', onTap: () => showDefaultSelection(context, 'income')),
          SettingsTile(icon: Icons.swap_vert_rounded, title: 'Account reorder', subtitle: 'Reorder account sequence', color: '#FBC879', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AccountReorderScreen()))),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: ExpressiveCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: colorFromHex('#9AD0F5').withOpacity(.16),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: colorFromHex('#9AD0F5').withOpacity(.20)),
                    ),
                    child: Icon(Icons.lock_rounded, color: colorFromHex('#9AD0F5')),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('App lock', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
                        const SizedBox(height: 4),
                        Text(
                          'Uses fingerprint or device PIN/password when available.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                  Switch(value: state.appLockEnabled, onChanged: state.setAppLock),
                ],
              ),
            ),
          ),
          SettingsTile(icon: Icons.backup_rounded, title: 'Backup', color: '#86E3CE', onTap: () => runBackupFlow(context, state)),
          SettingsTile(icon: Icons.restore_rounded, title: 'Restore', color: '#B4A5FF', onTap: () => runRestoreFlow(context, state)),
        ]),
      ),
    );
  }
}

Future<void> showDefaultSelection(BuildContext context, String mode) async {
  final state = context.read<AppController>();

  if (mode == 'account') {
    final selected = await showAppleWheelSelectionSheet(
      context,
      title: 'Choose Default Account',
      selectedId: state.defaultAccountId,
      options: state.accounts.map((account) => optionFromAccount(account, state)).toList(),
    );
    if (selected != null) await state.saveDefaults(accountId: selected);
    return;
  }

  final isIncome = mode == 'income';
  final categories = state.categories
      .where((category) => category.type == (isIncome ? CategoryType.income : CategoryType.expense) && !category.isLoanSystemCategory)
      .toList();

  final selected = await showAppleWheelSelectionSheet(
    context,
    title: isIncome ? 'Choose Default Income Category' : 'Choose Default Expense Category',
    selectedId: isIncome ? state.defaultIncomeCategoryId : state.defaultExpenseCategoryId,
    options: categories.map(optionFromCategory).toList(),
  );

  if (selected != null) {
    await state.saveDefaults(
      incomeCategoryId: isIncome ? selected : null,
      expenseCategoryId: isIncome ? null : selected,
    );
  }
}

class _AboutLink {
  const _AboutLink(this.label, this.shortLabel, this.icon, this.url);

  final String label;
  final String shortLabel;
  final IconData icon;
  final String url;
}

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const links = [
    _AboutLink('Telegram', 'Telegram', Icons.near_me_rounded, 'https://t.me/Ch0wdhury_Siam'),
    _AboutLink('Telegram backup', 'Telegram 2', Icons.send_rounded, 'https://t.me/Chowdhury_Siam'),
    _AboutLink('GitHub', 'GitHub', Icons.code_rounded, 'https://github.com/Chowdhury-Siam'),
    _AboutLink('MyAnimeList', 'MAL', Icons.format_list_bulleted_rounded, 'https://myanimelist.net/profile/Siam_Chowdhury'),
    _AboutLink('AniList', 'AniList', Icons.analytics_rounded, 'https://anilist.co/user/SiamChowdhury/'),
    _AboutLink('YouTube', 'YouTube', Icons.play_circle_fill_rounded, 'https://www.youtube.com/@SCS_Otaku'),
    _AboutLink('X / Twitter', 'X', Icons.close_rounded, 'https://x.com/SiamChowdhuryy'),
    _AboutLink('Email', 'Email', Icons.email_rounded, 'mailto:ssiam4235@gmail.com'),
  ];

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: 'About Us',
      child: ResponsiveContent(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExpressiveCard(
              child: Column(children: [
                const Icon(Icons.account_balance_wallet_rounded, size: 64),
                const SizedBox(height: 12),
                Text('Developed by Siam Chowdhury', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900), textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text('Version: $appVersion', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
                  runSpacing: 12,
                  children: links.map((link) => _AboutLinkButton(link: link)).toList(),
                ),
              ]),
            ),
            const SectionHeader('Legal'),
            SettingsTile(icon: Icons.privacy_tip_rounded, title: 'Privacy Policy', subtitle: 'Local data-first finance tracker', color: '#78D8E8', onTap: () => _showLegal(context, 'Privacy Policy')),
            SettingsTile(icon: Icons.description_rounded, title: 'Terms and conditions', subtitle: 'Usage terms', color: '#A6E3A1', onTap: () => _showLegal(context, 'Terms and conditions')),
            SettingsTile(icon: Icons.balance_rounded, title: 'Open-source licenses', subtitle: 'Apache License 2.0 and Flutter package notices', color: '#FBC879', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const KoinlyLicenseScreen()))),
          ],
        ),
      ),
    );
  }

  void _showLegal(BuildContext context, String title) {
    showDialog(context: context, builder: (_) => AlertDialog(title: Text(title), content: const Text('This Flutter rebuild keeps the original local-first behavior. Replace this placeholder with the production policy text used by the Kotlin release.'), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))]));
  }
}

class _AboutLinkButton extends StatelessWidget {
  const _AboutLinkButton({required this.link});

  final _AboutLink link;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: link.label,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: () => launchUrl(Uri.parse(link.url), mode: LaunchMode.externalApplication),
        child: SizedBox(
          width: 74,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withOpacity(0.72),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: scheme.outlineVariant.withOpacity(0.25)),
                ),
                child: Icon(link.icon, size: 26, color: scheme.onSurface),
              ),
              const SizedBox(height: 6),
              Text(
                link.shortLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w800,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LicensePackageSummary {
  const _LicensePackageSummary({required this.name, required this.entries});

  final String name;
  final int entries;
}

class KoinlyLicenseScreen extends StatefulWidget {
  const KoinlyLicenseScreen({super.key});

  @override
  State<KoinlyLicenseScreen> createState() => _KoinlyLicenseScreenState();
}

class _KoinlyLicenseScreenState extends State<KoinlyLicenseScreen> {
  late final Future<List<_LicensePackageSummary>> _licensesFuture = _loadLicenseSummaries();

  Future<List<_LicensePackageSummary>> _loadLicenseSummaries() async {
    final counts = <String, int>{};
    await for (final entry in LicenseRegistry.licenses) {
      for (final package in entry.packages) {
        counts[package] = (counts[package] ?? 0) + 1;
      }
    }
    final summaries = counts.entries
        .map((entry) => _LicensePackageSummary(name: entry.key, entries: entry.value))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return summaries;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PageScaffold(
      title: 'Licenses',
      subtitle: 'Open-source notices',
      child: FutureBuilder<List<_LicensePackageSummary>>(
        future: _licensesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not load open-source licenses.',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final licenses = snapshot.data ?? const <_LicensePackageSummary>[];
          return LayoutBuilder(
            builder: (context, constraints) {
              final screenWidth = MediaQuery.sizeOf(context).width;
              final desktop = screenWidth >= AppBreakpoints.expanded;
              final small = screenWidth < AppBreakpoints.compact;
              final maxWidth = desktop ? 980.0 : 720.0;
              final width = math.min(constraints.maxWidth, maxWidth).toDouble();
              final padding = EdgeInsets.fromLTRB(
                desktop ? 32 : small ? 14 : 18,
                desktop ? 22 : 12,
                desktop ? 32 : small ? 14 : 18,
                desktop ? 42 : 110,
              );

              return Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: width,
                  child: ListView.builder(
                    padding: padding,
                    physics: optimizedScrollPhysics(context),
                    itemCount: licenses.length + 1,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: ExpressiveCard(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                            child: Column(
                              children: [
                                Container(
                                  width: 72,
                                  height: 72,
                                  decoration: BoxDecoration(
                                    color: kSleekAccent.withOpacity(.16),
                                    borderRadius: AppShapes.large,
                                    border: Border.all(color: kSleekAccent.withOpacity(.22)),
                                  ),
                                  child: const Icon(Icons.account_balance_wallet_rounded, color: kSleekAccent, size: 38),
                                ),
                                const SizedBox(height: 14),
                                Text(appTitle, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900), textAlign: TextAlign.center),
                                const SizedBox(height: 4),
                                Text('Version $appVersion', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w800), textAlign: TextAlign.center),
                                const SizedBox(height: 12),
                                Text(
                                  'Powered by Flutter • ${licenses.length} packages with license notices',
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        );
                      }

                      final item = licenses[index - 1];
                      final countLabel = item.entries == 1 ? '1 license' : '${item.entries} licenses';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: ExpressiveCard(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: kSleekAccent.withOpacity(.14),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: kSleekAccent.withOpacity(.20)),
                              ),
                              child: const Icon(Icons.article_rounded, color: kSleekAccent),
                            ),
                            title: Text(
                              item.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w900),
                            ),
                            subtitle: Text(countLabel, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700)),
                            trailing: Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => KoinlyLicenseDetailScreen(packageName: item.name, licenseCount: item.entries)),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class KoinlyLicenseDetailScreen extends StatefulWidget {
  const KoinlyLicenseDetailScreen({super.key, required this.packageName, required this.licenseCount});

  final String packageName;
  final int licenseCount;

  @override
  State<KoinlyLicenseDetailScreen> createState() => _KoinlyLicenseDetailScreenState();
}

class _KoinlyLicenseDetailScreenState extends State<KoinlyLicenseDetailScreen> {
  late final Future<List<LicenseEntry>> _entriesFuture = _loadEntries();

  Future<List<LicenseEntry>> _loadEntries() async {
    final entries = <LicenseEntry>[];
    await for (final entry in LicenseRegistry.licenses) {
      if (entry.packages.contains(widget.packageName)) {
        entries.add(entry);
      }
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PageScaffold(
      title: widget.packageName,
      subtitle: widget.licenseCount == 1 ? '1 license notice' : '${widget.licenseCount} license notices',
      child: FutureBuilder<List<LicenseEntry>>(
        future: _entriesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final entries = snapshot.data ?? const <LicenseEntry>[];
          return LayoutBuilder(
            builder: (context, constraints) {
              final screenWidth = MediaQuery.sizeOf(context).width;
              final desktop = screenWidth >= AppBreakpoints.expanded;
              final small = screenWidth < AppBreakpoints.compact;
              final maxWidth = desktop ? 980.0 : 720.0;
              final width = math.min(constraints.maxWidth, maxWidth).toDouble();
              final padding = EdgeInsets.fromLTRB(
                desktop ? 32 : small ? 14 : 18,
                desktop ? 22 : 12,
                desktop ? 32 : small ? 14 : 18,
                desktop ? 42 : 110,
              );

              return Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: width,
                  child: SelectionArea(
                    child: ListView.builder(
                      padding: padding,
                      physics: optimizedScrollPhysics(context),
                      itemCount: entries.length + 1,
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: ExpressiveCard(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(widget.packageName, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900)),
                                  const SizedBox(height: 8),
                                  Text(
                                    widget.licenseCount == 1 ? '1 license notice' : '${widget.licenseCount} license notices',
                                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }

                        final entry = entries[index - 1];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: ExpressiveCard(
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: entry.paragraphs
                                  .map(
                                    (paragraph) => Padding(
                                      padding: EdgeInsets.only(left: paragraph.indent == LicenseParagraph.centeredIndent ? 0 : paragraph.indent * 16.0, bottom: 10),
                                      child: SelectableText(
                                        paragraph.text,
                                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                              color: scheme.onSurfaceVariant,
                                              height: 1.42,
                                              fontWeight: paragraph.indent == LicenseParagraph.centeredIndent ? FontWeight.w800 : FontWeight.w500,
                                            ),
                                        textAlign: paragraph.indent == LicenseParagraph.centeredIndent ? TextAlign.center : TextAlign.start,
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
