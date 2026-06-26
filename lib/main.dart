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
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
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
const appVersion = '1.0.0';
const backupPassword = 'YOUR_SECRET_PASSWORD';
const kSyncAdminTelegramUrl = 'https://t.me/Ch0wdhury_Siam';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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

enum AccountType { regular, credit }
enum CategoryType { income, expense }
enum MoneyTransactionType { income, expense, transfer }
enum LoanType { given, taken }
enum LoanStatus { open, completed }
enum DateRangeType { today, thisWeek, thisMonth, thisYear, allTime, custom }
enum CurrencyPosition { prefix, suffix }
enum ThemePreference { system, light, dark, batterySaver }

String enumName(Object value) => value.toString().split('.').last;

T enumByName<T>(Iterable<T> values, String? name, T fallback) {
  if (name == null) return fallback;
  for (final value in values) {
    if (enumName(value as Object) == name) return value;
  }
  return fallback;
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
    final tables = ['accounts', 'categories', 'transactions', 'budgets', 'budget_accounts', 'budget_categories', 'loans', 'loan_repayments'];
    final data = <String, dynamic>{};
    for (final table in tables) {
      data[table] = await database.query(table);
    }
    return data;
  }

  Future<void> importAll(Map<String, dynamic> data) async {
    final database = await db;
    final tables = ['loan_repayments', 'loans', 'budget_categories', 'budget_accounts', 'budgets', 'transactions', 'categories', 'accounts'];
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

class ReminderService {
  static final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();

  static Future<void> ensureInitialized() async {
    tzdata.initializeTimeZones();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    await _notifications.initialize(settings);
    final androidPlugin = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestNotificationsPermission();
  }

  static Future<void> scheduleDaily(TimeOfDay time) async {
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

  static Future<void> cancel() => _notifications.cancel(501);
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

  bool loading = true;
  bool onboardingCompleted = false;
  bool authenticated = false;
  int tabIndex = 0;
  LoanType activeLoanType = LoanType.given;

  List<Account> accounts = [];
  List<Category> categories = [];
  List<MoneyTransaction> transactions = [];
  List<Budget> budgets = [];
  List<Loan> loans = [];

  ThemePreference themePreference = ThemePreference.system;
  String currencySymbol = '৳';
  String currencyCode = 'BDT';
  CurrencyPosition currencyPosition = CurrencyPosition.suffix;
  bool useSeparators = true;
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
  String cloudSyncApiBaseUrl = CloudSyncService.configuredApiBaseUrl;
  String cloudSyncId = '';
  String cloudSyncPin = '';
  bool cloudSyncBusy = false;
  String? cloudSyncError;
  String? cloudSyncErrorCode;
  DateTime? cloudSyncLastAt;
  Timer? _cloudSyncDebounce;

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
  }

  Future<void> _loadPreferences() async {
    onboardingCompleted = await prefs.getBool('onboardingCompleted', false);
    themePreference = await prefs.getEnum('themePreference', ThemePreference.values, ThemePreference.system);
    currencySymbol = await prefs.getString('currencySymbol', '৳');
    currencyCode = await prefs.getString('currencyCode', 'BDT');
    currencyPosition = await prefs.getEnum('currencyPosition', CurrencyPosition.values, CurrencyPosition.suffix);
    useSeparators = await prefs.getBool('useSeparators', true);
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
    cloudSyncEnabled = await prefs.getBool('cloudSyncEnabled', false);
    final savedCloudSyncApiBaseUrl = await prefs.getString('cloudSyncApiBaseUrl', '');
    cloudSyncApiBaseUrl = CloudSyncService.resolveApiBaseUrl(savedCloudSyncApiBaseUrl);
    cloudSyncId = await prefs.getString('cloudSyncId', '');
    cloudSyncPin = await prefs.getString('cloudSyncPin', '');
    final lastSyncRaw = await prefs.getString('cloudSyncLastAt', '');
    cloudSyncLastAt = lastSyncRaw.isEmpty ? null : DateTime.tryParse(lastSyncRaw);
  }

  Future<Map<String, dynamic>> exportPreferences() async => {
        'onboardingCompleted': onboardingCompleted,
        'themePreference': enumName(themePreference),
        'currencySymbol': currencySymbol,
        'currencyCode': currencyCode,
        'currencyPosition': enumName(currencyPosition),
        'useSeparators': useSeparators,
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
      };

  Future<void> importPreferences(Map<String, dynamic> data) async {
    final sp = await prefs.prefs;
    for (final entry in data.entries) {
      final value = entry.value;
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
    if (cloudSyncBusy) return 'Syncing...';
    if (cloudSyncErrorCode == 'SYNC_APPROVAL_REQUIRED') return 'Admin approval required';
    if (cloudSyncError != null && cloudSyncError!.trim().isNotEmpty) return 'Error: $cloudSyncError';
    if (!cloudSyncEnabled) return 'Disabled';
    if (cloudSyncLastAt == null) return 'Enabled • Not synced yet';
    return 'Enabled • Last sync ${DateFormat('yyyy-MM-dd HH:mm').format(cloudSyncLastAt!.toLocal())}';
  }

  bool get cloudSyncApprovalRequired => cloudSyncErrorCode == 'SYNC_APPROVAL_REQUIRED';

  Future<void> configureCloudSync({required bool enabled, required String apiBaseUrl, required String syncId, required String pin}) async {
    cloudSyncEnabled = enabled;
    cloudSyncApiBaseUrl = CloudSyncService.resolveApiBaseUrl(apiBaseUrl);
    cloudSyncId = CloudSyncService.normalizeSyncId(syncId);
    cloudSyncPin = pin.trim();
    cloudSyncError = null;
    cloudSyncErrorCode = null;
    await prefs.setBool('cloudSyncEnabled', cloudSyncEnabled);
    await prefs.setString('cloudSyncApiBaseUrl', cloudSyncApiBaseUrl);
    await prefs.setString('cloudSyncId', cloudSyncId);
    await prefs.setString('cloudSyncPin', cloudSyncPin);
    notifyListeners();
  }

  Future<void> syncToCloud({bool force = false}) async {
    if (cloudSyncBusy) return;
    if (!force && !cloudSyncEnabled) return;
    if (cloudSyncId.trim().isEmpty || cloudSyncPin.trim().isEmpty) {
      cloudSyncError = 'Add a Sync ID and PIN first.';
      notifyListeners();
      return;
    }
    cloudSyncBusy = true;
    cloudSyncError = null;
    cloudSyncErrorCode = null;
    notifyListeners();
    try {
      await CloudSyncService.upload(apiBaseUrl: cloudSyncApiBaseUrl, syncId: cloudSyncId, pin: cloudSyncPin, payload: await exportCloudPayload());
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

  Future<void> syncFromCloud() async {
    if (cloudSyncBusy) return;
    if (cloudSyncId.trim().isEmpty || cloudSyncPin.trim().isEmpty) {
      cloudSyncError = 'Add a Sync ID and PIN first.';
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
      await prefs.setString('cloudSyncPin', cloudSyncPin);
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

  void queueCloudSync() {
    if (!cloudSyncEnabled || cloudSyncId.trim().isEmpty || cloudSyncPin.trim().isEmpty) return;
    _cloudSyncDebounce?.cancel();
    _cloudSyncDebounce = Timer(const Duration(seconds: 3), () {
      unawaited(syncToCloud());
    });
  }

  String _cleanSyncError(Object error) {
    final text = error.toString().replaceFirst('Exception: ', '').replaceFirst('Bad state: ', '').trim();
    return text.isEmpty ? 'Sync failed. Check your internet and Turso setup.' : text;
  }

  @override
  void dispose() {
    _cloudSyncDebounce?.cancel();
    super.dispose();
  }

  Future<void> reload({bool queueSync = false}) async {
    accounts = await database.accounts();
    categories = await database.categories();
    transactions = await database.transactions();
    budgets = await database.budgets();
    loans = await database.loans();
    defaultAccountId ??= accounts.isNotEmpty ? accounts.first.id : null;
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
    await prefs.setBool('onboardingCompleted', true);
    notifyListeners();
  }

  Account? accountOf(String id) => accounts.where((a) => a.id == id).firstOrNull;
  Category? categoryOf(String id) => categories.where((c) => c.id == id).firstOrNull;

  double get totalAccountBalance => accounts.fold<double>(0, (sum, account) => sum + account.amount);

  String format(double amount) {
    final formatter = NumberFormat(useSeparators ? '#,##0.##' : '0.##');
    final num = formatter.format(amount.abs());
    final sign = amount < 0 ? '-' : '';
    return currencyPosition == CurrencyPosition.prefix ? '$sign$currencySymbol$num' : '$sign$num$currencySymbol';
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
      if (filterCategoryIds.isNotEmpty && !filterCategoryIds.contains(tx.categoryId)) return false;
      if (filterTypes.isNotEmpty && (tx.isLoanMovement || !filterTypes.contains(tx.type))) return false;
      if (categoryId != null && tx.categoryId != categoryId) return false;
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
  Future<void> deleteLoan(String id) async { await database.deleteLoan(id); await reload(queueSync: true); }
  Future<void> addRepayment(Loan loan, LoanRepayment repayment, String accountId) async { await database.addRepayment(loan, repayment, accountId); await reload(queueSync: true); }
  Future<void> deleteRepayment(String id) async { await database.deleteRepayment(id); await reload(queueSync: true); }
}

extension FirstOrNullExtension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

// -----------------------------------------------------------------------------
// App shell and shared UI
// -----------------------------------------------------------------------------

class KoinlyApp extends StatelessWidget {
  const KoinlyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: appTitle,
      themeMode: state.themeMode,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: const StartupGate(),
    );
  }

  ThemeData _theme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: kSleekAccent,
      brightness: brightness,
    );
    final darkScheme = scheme.copyWith(
      primary: kSleekAccent,
      secondary: const Color(0xFF2BD9A1),
      tertiary: const Color(0xFFFF5C7A),
      surface: kSleekSurface,
      surfaceContainerHighest: kSleekSurfaceHigh,
      background: kSleekBackground,
      outline: const Color(0xFF2A3940),
      outlineVariant: const Color(0xFF1D2A30),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: isDark ? darkScheme : scheme.copyWith(primary: kSleekAccent),
      scaffoldBackgroundColor: isDark ? kSleekBackground : const Color(0xFFF5FAFB),
      canvasColor: isDark ? kSleekBackground : const Color(0xFFF5FAFB),
      visualDensity: VisualDensity.compact,
      dividerColor: Colors.transparent,
      cardTheme: CardThemeData(
        elevation: 0,
        color: isDark ? kSleekSurface : Colors.white,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? const Color(0xEE0B1417) : Colors.white,
        indicatorColor: kSleekAccent.withOpacity(.18),
        height: 76,
        elevation: 0,
        shadowColor: Colors.transparent,
        labelTextStyle: WidgetStatePropertyAll(TextStyle(fontWeight: FontWeight.w800, fontSize: 11, color: isDark ? const Color(0xFFE7F4F6) : const Color(0xFF0F172A))),
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
              color: states.contains(WidgetState.selected) ? kSleekAccent : (isDark ? const Color(0xFFB8C5CB) : const Color(0xFF64748B)),
              size: states.contains(WidgetState.selected) ? 25 : 23,
            )),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? kSleekSurfaceHigh : Colors.white,
        hintStyle: TextStyle(color: isDark ? const Color(0xFF819099) : const Color(0xFF64748B)),
        labelStyle: TextStyle(color: isDark ? const Color(0xFFB7C4CB) : const Color(0xFF475569)),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide(color: kSleekAccent.withOpacity(.7), width: 1.2)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: kSleekAccent,
          foregroundColor: const Color(0xFF021012),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
          textStyle: const TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: isDark ? const Color(0xFFDDECEF) : const Color(0xFF0F172A),
          side: BorderSide(color: isDark ? const Color(0xFF2E424A) : const Color(0xFFD1D5DB), width: 1.2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? kSleekAccent.withOpacity(.55) : (isDark ? kSleekSurface : Colors.white)),
          foregroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? const Color(0xFFEFFFFF) : (isDark ? const Color(0xFFB8C5CB) : const Color(0xFF334155))),
          side: WidgetStatePropertyAll(BorderSide(color: isDark ? const Color(0xFF31424A) : const Color(0xFFD1D5DB), width: 1.2)),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontWeight: FontWeight.w800)),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 13, horizontal: 16)),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: kSleekAccent,
        foregroundColor: const Color(0xFF021012),
        elevation: 10,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          backgroundColor: isDark ? kSleekSurfaceHigh.withOpacity(.75) : Colors.white,
          foregroundColor: isDark ? const Color(0xFFE6F1F3) : const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: isDark ? kSleekBackground : const Color(0xFFF5FAFB),
        surfaceTintColor: Colors.transparent,
        iconTheme: IconThemeData(color: isDark ? const Color(0xFFE6F1F3) : const Color(0xFF0F172A)),
        titleTextStyle: TextStyle(color: isDark ? const Color(0xFFE6F1F3) : const Color(0xFF0F172A), fontWeight: FontWeight.w900, fontSize: 26),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: isDark ? kSleekSurfaceHigh : const Color(0xFFEFF6F8),
        selectedColor: kSleekAccent.withOpacity(.45),
        side: BorderSide(color: isDark ? const Color(0xFF2E424A) : const Color(0xFFD9E5E8)),
        labelStyle: TextStyle(color: isDark ? const Color(0xFFE6F1F3) : const Color(0xFF0F172A), fontWeight: FontWeight.w700),
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
    if (!state.onboardingCompleted) return const OnboardingScreen();
    return const MainShell();
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
            Hero(
              tag: 'app-icon',
              child: Container(
                width: 92,
                height: 92,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(30),
                  gradient: LinearGradient(colors: [Theme.of(context).colorScheme.primary, Theme.of(context).colorScheme.tertiary]),
                ),
                child: const Icon(Icons.account_balance_wallet_rounded, size: 48, color: Colors.white),
              ),
            ),
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

    return Scaffold(
      extendBody: true,
      body: Stack(
        children: [
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              child: pages[state.tabIndex],
            ),
          ),
          if (actionButton != null)
            Positioned(
              right: 28,
              bottom: MediaQuery.of(context).padding.bottom + 102,
              child: actionButton,
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _FloatingDockNavigation(
              selectedIndex: state.tabIndex,
              onSelected: (index) {
                state.tabIndex = index;
                state.notifyListeners();
              },
            ),
          ),
        ],
      ),
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
                            duration: const Duration(milliseconds: 190),
                            curve: Curves.easeOutCubic,
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
    return Scaffold(
      backgroundColor: scheme.background,
      appBar: AppBar(
        toolbarHeight: 78,
        titleSpacing: 18,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).appBarTheme.titleTextStyle?.copyWith(fontSize: 28)),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(subtitle!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
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
  const ResponsiveContent({super.key, required this.child, this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 110)});
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth > 720 ? 720.0 : constraints.maxWidth;
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: width,
            child: SingleChildScrollView(
              padding: padding,
              physics: const BouncingScrollPhysics(),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

class ExpressiveCard extends StatelessWidget {
  const ExpressiveCard({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.color});
  final Widget child;
  final EdgeInsets padding;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = color ?? (dark ? kSleekSurface : Colors.white);
    return Container(
      decoration: BoxDecoration(
        color: baseColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: dark ? const Color(0xFF1F3036) : const Color(0xFFE4EEF1), width: 1),
        boxShadow: [
          if (dark)
            BoxShadow(color: Colors.black.withOpacity(.22), blurRadius: 18, offset: const Offset(0, 10))
          else
            BoxShadow(color: scheme.shadow.withOpacity(.06), blurRadius: 18, offset: const Offset(0, 10)),
        ],
      ),
      child: Padding(padding: padding, child: child),
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

    return Material(
      color: selected ? selectedColor : unselectedColor,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          constraints: const BoxConstraints(minHeight: 58),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: borderColor, width: 1),
            boxShadow: selected
                ? [BoxShadow(color: kSleekAccent.withOpacity(.10), blurRadius: 16, offset: const Offset(0, 8))]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (option.icon != null) ...[
                Icon(option.icon, size: 20, color: selected ? kSleekAccent : textColor),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  option.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: textColor,
                        fontWeight: FontWeight.w900,
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
    case 'flag': return Icons.flag_rounded;
    case 'profile': return Icons.account_circle_rounded;
    case 'loan_given': return Icons.call_made_rounded;
    case 'loan_taken': return Icons.call_received_rounded;
    case 'loan_received': return Icons.south_west_rounded;
    case 'loan_paid': return Icons.north_east_rounded;
    default: return Icons.category_rounded;
  }
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
      boxShadow: [BoxShadow(color: c.withOpacity(.12), blurRadius: 12, offset: const Offset(0, 5))],
    ),
    child: Icon(iconFor(icon), color: c, size: size * .52),
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
      subtitle: account.type == AccountType.credit ? 'Credit • Available ${state.format(account.availableCredit)}' : 'Regular account',
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

  final result = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      return StatefulBuilder(
        builder: (context, setModalState) {
          final safeIndex = selectedIndex < 0 ? 0 : selectedIndex >= options.length ? options.length - 1 : selectedIndex;
          final selected = options[safeIndex];
          final scheme = Theme.of(context).colorScheme;
          final dark = Theme.of(context).brightness == Brightness.dark;
          final sheetColor = dark ? const Color(0xFF10191D) : Colors.white;
          final innerColor = dark ? const Color(0xFF0B1417) : const Color(0xFFF5FAFB);
          final borderColor = dark ? const Color(0xFF24343A) : const Color(0xFFDCE8EB);
          final innerBorderColor = dark ? const Color(0xFF1F3036) : const Color(0xFFDCE8EB);
          final handleColor = dark ? const Color(0xFF43545B) : const Color(0xFFB7C8CE);

          return SafeArea(
            top: false,
            child: Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              decoration: BoxDecoration(
                color: sheetColor,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: borderColor),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(.45), blurRadius: 28, offset: const Offset(0, -8))],
              ),
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
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
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
                        iconBubble(context, selected.iconName, selected.iconColor, size: 40),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            selected.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900),
                          ),
                        ),
                        Text(
                          selected.subtitle,
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: FilledButton(
                          onPressed: () => Navigator.pop(sheetContext, options[safeIndex].id),
                          child: const Text('Done'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
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

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: controller,
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
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Row(
                    children: List.generate(4, (i) => AnimatedContainer(
                          duration: const Duration(milliseconds: 240),
                          width: i == index ? 24 : 8,
                          height: 8,
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(borderRadius: BorderRadius.circular(99), color: i == index ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outlineVariant),
                        )),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () async {
                      if (index < 3) {
                        controller.nextPage(duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
                      } else {
                        await state.completeOnboarding();
                      }
                    },
                    child: Text(index < 3 ? 'Next' : 'Start'),
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

class _OnboardingPane extends StatelessWidget {
  const _OnboardingPane({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Hero(
            tag: 'app-icon',
            child: Container(
              width: 110,
              height: 110,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(36),
                gradient: LinearGradient(colors: [Theme.of(context).colorScheme.primary, Theme.of(context).colorScheme.tertiary]),
              ),
              child: Icon(icon, size: 58, color: Colors.white),
            ),
          ),
          const SizedBox(height: 32),
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
    return ResponsiveContent(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(height: 80),
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
    return ResponsiveContent(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 80),
          Text('Accounts are ready', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900)),
          const SizedBox(height: 12),
          const Text('The app preloads Cash, Card, and Bank Account. You can create, edit, delete, reorder, and configure credit limits later.'),
          const SizedBox(height: 24),
          ...state.accounts.map((a) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: AccountTile(account: a, onTap: () => showAccountEditor(context, account: a)),
              )),
          OutlinedButton.icon(onPressed: () => showAccountEditor(context), icon: const Icon(Icons.add_rounded), label: const Text('Create account')),
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
    final recent = txs.take(5).toList();
    final categoryTotals = state.categoryTotals(CategoryType.expense);
    final topCategories = categoryTotals.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    return PageScaffold(
      title: 'Home',
      subtitle: range.label,
      actions: [
        IconButton(onPressed: () => showDateRangeSheet(context), icon: const Icon(Icons.date_range_rounded)),
        IconButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())), icon: const Icon(Icons.settings_rounded)),
      ],
      child: ResponsiveContent(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BalanceHeroCard(
              balance: state.format(accountBalance),
              income: state.format(summary.income),
              expense: state.format(summary.expense),
              subtitle: '${state.accounts.length} accounts total • ${state.activeRange().label} balance ${state.format(summary.balance)}',
            ),
            SectionHeader('Accounts', trailing: TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AccountListScreen())), child: const Text('View all'))),
            ...state.accounts.take(3).map((account) => Padding(padding: const EdgeInsets.only(bottom: 10), child: AccountTile(account: account, onTap: () => showAccountEditor(context, account: account)))),
            SectionHeader('Budgets', trailing: TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BudgetListScreen())), child: const Text('View all'))),
            if (state.budgets.isEmpty)
              EmptyCard(icon: Icons.savings_rounded, title: 'No budget yet', body: 'Create a monthly budget and track spending against limits.', action: () => showBudgetEditor(context), actionLabel: 'Create budget')
            else
              ...state.budgetProgress().take(2).map((b) => Padding(padding: const EdgeInsets.only(bottom: 10), child: BudgetProgressTile(progress: b))),
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
            SectionHeader('Recent transactions', trailing: TextButton(onPressed: () { state.tabIndex = 3; state.notifyListeners(); }, child: const Text('View all'))),
            if (recent.isEmpty)
              EmptyCard(icon: Icons.receipt_long_rounded, title: 'No transactions', body: 'Use the quick add button to create income, expense, or transfer records.', action: () => showTransactionEditor(context), actionLabel: 'Add transaction')
            else
              ...recent.map((tx) => Padding(padding: const EdgeInsets.only(bottom: 10), child: TransactionTile(tx: tx))),
          ],
        ),
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
  const BalanceHeroCard({super.key, required this.balance, required this.income, required this.expense, required this.subtitle});
  final String balance;
  final String income;
  final String expense;
  final String subtitle;

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
        boxShadow: [
          BoxShadow(color: kSleekAccent.withOpacity(dark ? .10 : .08), blurRadius: 28, offset: const Offset(0, 14)),
          BoxShadow(color: Colors.black.withOpacity(dark ? .30 : .08), blurRadius: 22, offset: const Offset(0, 12)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Net Balance', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: titleColor, fontWeight: FontWeight.w800)),
              const SizedBox(width: 6),
              Icon(Icons.visibility_rounded, size: 15, color: dark ? const Color(0xFF9EDDE7) : kSleekAccent.withOpacity(.82)),
            ],
          ),
          const SizedBox(height: 10),
          Text(balance, style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -1.2, color: valueColor)),
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
    return SizedBox(
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
          account.type == AccountType.credit ? 'Credit • Available ${state.format(account.availableCredit)}' : 'Cash Wallet',
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
  const AccountListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    return PageScaffold(
      title: 'Accounts',
      actions: [
        IconButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AccountReorderScreen())), icon: const Icon(Icons.swap_vert_rounded)),
        IconButton(onPressed: () => showAccountEditor(context), icon: const Icon(Icons.add_rounded)),
      ],
      child: ResponsiveContent(
        child: Column(children: state.accounts.map((account) => Padding(padding: const EdgeInsets.only(bottom: 10), child: AccountTile(account: account, onTap: () => showAccountEditor(context, account: account)))).toList()),
      ),
    );
  }
}

class AccountReorderScreen extends StatefulWidget {
  const AccountReorderScreen({super.key});

  @override
  State<AccountReorderScreen> createState() => _AccountReorderScreenState();
}

class _AccountReorderScreenState extends State<AccountReorderScreen> {
  late List<Account> items;

  @override
  void initState() {
    super.initState();
    items = List.of(context.read<AppController>().accounts);
  }

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: 'Reorder accounts',
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

Future<void> showAccountEditor(BuildContext context, {Account? account}) async {
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => AccountEditor(account: account),
  );
}

class AccountEditor extends StatefulWidget {
  const AccountEditor({super.key, this.account});
  final Account? account;

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

  @override
  void initState() {
    super.initState();
    final a = widget.account;
    if (a != null) {
      name.text = a.name;
      amount.text = a.amount.toStringAsFixed(2);
      creditLimit.text = a.creditLimit.toStringAsFixed(2);
      type = a.type;
      icon = a.iconName;
      color = a.iconColor;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    return Padding(
      padding: EdgeInsets.only(left: 18, right: 18, bottom: MediaQuery.of(context).viewInsets.bottom + 18),
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
              options: const [
                SleekPillOption(value: AccountType.regular, label: 'Regular', icon: Icons.account_balance_wallet_rounded),
                SleekPillOption(value: AccountType.credit, label: 'Credit', icon: Icons.credit_card_rounded),
              ],
              selected: type,
              onChanged: (v) => setState(() => type = v),
            ),
            const SizedBox(height: 12),
            TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Balance')),
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
    'sports', 'fitness', 'book', 'school', 'car', 'bus', 'train', 'flight', 'fuel',
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
      child: Icon(iconFor(icon), color: Colors.white, size: 30),
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

    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            decoration: BoxDecoration(
              color: Theme.of(sheetContext).brightness == Brightness.dark ? kSleekSurface : Colors.white,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Theme.of(sheetContext).brightness == Brightness.dark ? const Color(0xFF24343A) : const Color(0xFFDCE8EB)),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(.45), blurRadius: 28, offset: const Offset(0, -8))],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(color: Theme.of(sheetContext).brightness == Brightness.dark ? const Color(0xFF43545B) : const Color(0xFFB7C8CE), borderRadius: BorderRadius.circular(999)),
                ),
                const SizedBox(height: 18),
                Text(
                  'Custom color',
                  style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 6),
                Text(
                  'Choose how you want to create a custom color.',
                  textAlign: TextAlign.center,
                  style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 16),
                _CustomColorOptionCard(
                  icon: Icons.palette_rounded,
                  title: 'Color picker',
                  subtitle: 'Use color wheel, brightness, and HEX input',
                  onTap: () => Navigator.pop(sheetContext, 'wheel'),
                ),
                const SizedBox(height: 10),
                _CustomColorOptionCard(
                  icon: Icons.photo_library_rounded,
                  title: 'Pick from photo',
                  subtitle: 'Upload a photo and tap any pixel color',
                  onTap: () => Navigator.pop(sheetContext, 'photo'),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    child: const Text('Cancel'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
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
                      Icon(iconFor(icon), color: selected ? selectedColorValue : Theme.of(context).colorScheme.onSurface, size: 28),
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
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => CategoryEditor(category: category, initialType: initialType),
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
      padding: EdgeInsets.only(left: 18, right: 18, bottom: MediaQuery.of(context).viewInsets.bottom + 18),
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
      child: ResponsiveContent(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ActiveFilterChips(state: state),
            if (txs.isEmpty)
              EmptyCard(icon: Icons.receipt_long_rounded, title: 'No transactions', body: 'Create a transaction or change filters.', action: () => showTransactionEditor(context), actionLabel: 'Add transaction')
            else
              ...txs.map((tx) => Padding(padding: const EdgeInsets.only(bottom: 10), child: TransactionTile(tx: tx))),
          ],
        ),
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
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => TransactionEditor(transaction: transaction, lockedCategory: lockedCategory),
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
      fromAccountId = state.defaultAccountId ?? state.accounts.firstOrNull?.id;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final relevantCategories = state.categories.where((c) => c.type == (type == MoneyTransactionType.income ? CategoryType.income : CategoryType.expense) && !c.isLoanSystemCategory).toList();
    if (type == MoneyTransactionType.transfer) categoryId = categoryId ?? state.categories.firstOrNull?.id;
    return Padding(
      padding: EdgeInsets.only(left: 18, right: 18, bottom: MediaQuery.of(context).viewInsets.bottom + 18),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.transaction == null ? 'Add transaction' : 'Edit transaction', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 16),
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
                }
              }),
            ),
            const SizedBox(height: 16),
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
              option: state.accounts.where((a) => a.id == fromAccountId).firstOrNull == null ? null : optionFromAccount(state.accounts.where((a) => a.id == fromAccountId).first, state),
              emptyText: 'Choose account',
              onTap: () async {
                final selected = await showAppleWheelSelectionSheet(
                  context,
                  title: type == MoneyTransactionType.transfer ? 'Choose From Account' : 'Choose Account',
                  selectedId: fromAccountId,
                  options: state.accounts.map((a) => optionFromAccount(a, state)).toList(),
                );
                if (selected != null) setState(() => fromAccountId = selected);
              },
            ),
            if (type == MoneyTransactionType.transfer) ...[
              const SizedBox(height: 12),
              AppleSelectionField(
                label: 'To account',
                option: state.accounts.where((a) => a.id == toAccountId).firstOrNull == null ? null : optionFromAccount(state.accounts.where((a) => a.id == toAccountId).first, state),
                emptyText: 'Choose destination account',
                onTap: () async {
                  final selected = await showAppleWheelSelectionSheet(
                    context,
                    title: 'Choose To Account',
                    selectedId: toAccountId,
                    options: state.accounts.map((a) => optionFromAccount(a, state)).toList(),
                  );
                  if (selected != null) setState(() => toAccountId = selected);
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
                  categoryId: categoryId ?? '',
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
      padding: const EdgeInsets.all(12),
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
            style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w900),
            decoration: const InputDecoration(prefixIcon: Icon(Icons.calculate_rounded), labelText: 'Amount'),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              const spacing = 10.0;
              final buttonWidth = (constraints.maxWidth - spacing * 2) / 3;
              final buttonHeight = (buttonWidth * 0.42).clamp(54.0, 72.0).toDouble();
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
      borderRadius: BorderRadius.circular(24),
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
                fontSize: 26,
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
  await showModalBottomSheet(context: context, showDragHandle: true, builder: (_) => const DateRangeSheet());
}

class DateRangeSheet extends StatelessWidget {
  const DateRangeSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Date range', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: DateRangeType.values.map((t) => ChoiceChip(label: Text(_rangeLabel(t)), selected: state.dateRangeType == t, onSelected: (_) async {
              if (t == DateRangeType.custom) {
                final start = await pickDate(context, state.customStart ?? DateTime.now());
                if (!context.mounted || start == null) return;
                final end = await pickDate(context, state.customEnd ?? start);
                await state.setDateRange(t, start: start, end: end ?? start);
              } else {
                await state.setDateRange(t);
              }
              if (context.mounted) Navigator.pop(context);
            })).toList(),
          ),
        ],
      ),
    );
  }

  String _rangeLabel(DateRangeType type) => _dateRangeLabel(type);
}

Future<void> showFilterSheet(BuildContext context) async {
  await showModalBottomSheet(context: context, isScrollControlled: true, showDragHandle: true, builder: (_) => const FilterSheet());
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
      padding: EdgeInsets.only(left: 18, right: 18, bottom: MediaQuery.of(context).viewInsets.bottom + 18),
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

class AnalysisScreen extends StatelessWidget {
  const AnalysisScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final range = state.activeRange();
    final txs = state.filteredTransactions();
    final summary = state.summaryFor(txs);
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
    List<DateTime> days;
    if (range.start != null && range.end != null) {
      final totalDays = range.end!.difference(range.start!).inDays;
      if (totalDays > 0 && totalDays <= 62) {
        days = List.generate(
          totalDays,
          (index) => DateTime(range.start!.year, range.start!.month, range.start!.day).add(Duration(days: index)),
        );
      } else {
        days = daily.keys.toList()..sort();
      }
    } else if (daily.isNotEmpty) {
      days = daily.keys.toList()..sort();
    } else {
      final today = DateTime.now();
      days = [DateTime(today.year, today.month, today.day)];
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
            AnalysisTrendChart(days: days, daily: daily, rangeLabel: range.label),
            const SectionHeader('Averages'),
            Row(children: [
              Expanded(child: MiniMetric('Income / day', state.format(summary.income / avgDivisor), Icons.trending_up_rounded)),
              const SizedBox(width: 10),
              Expanded(child: MiniMetric('Expense / day', state.format(summary.expense / avgDivisor), Icons.trending_down_rounded)),
            ]),
            const SectionHeader('Category analytics'),
            CategoryBreakdownCard(type: CategoryType.expense),
            const SizedBox(height: 12),
            CategoryBreakdownCard(type: CategoryType.income),
          ],
        ),
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

  static const Color _incomeColor = Color(0xFF18D6E3);
  static const Color _expenseColor = Color(0xFFFF5B57);

  List<FlSpot> _spots(double Function(Summary summary) valueOf) {
    if (days.isEmpty) return const [FlSpot(0, 0), FlSpot(1, 0)];
    final result = <FlSpot>[];
    for (var i = 0; i < days.length; i++) {
      result.add(FlSpot(i.toDouble(), valueOf(daily[days[i]] ?? const Summary(income: 0, expense: 0))));
    }
    if (result.length == 1) result.add(FlSpot(1, result.first.y));
    return result;
  }

  double _maxY(List<FlSpot> income, List<FlSpot> expense) {
    final highest = [...income, ...expense].fold<double>(0, (max, spot) => math.max(max, spot.y));
    if (highest <= 0) return 100;
    final padded = highest * 1.20;
    final magnitude = math.pow(10, (math.log(padded) / math.ln10).floor()).toDouble();
    final normalized = padded / magnitude;
    final rounded = normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10;
    return rounded * magnitude;
  }

  String _compactCurrency(AppController state, double value) {
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

  Widget _leftTitle(BuildContext context, double value, TitleMeta meta, double maxY) {
    final allowed = [0.0, maxY / 2, maxY];
    final match = allowed.any((v) => (value - v).abs() < 0.01);
    if (!match) return const SizedBox.shrink();
    final state = context.read<AppController>();
    return Text(
      _compactCurrency(state, value),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurface.withOpacity(.58),
            fontWeight: FontWeight.w700,
          ),
    );
  }

  Widget _bottomTitle(BuildContext context, double value, TitleMeta meta) {
    if (days.isEmpty) return const SizedBox.shrink();
    final indexes = <int>{
      0,
      if (days.length > 2) (days.length * .25).round(),
      if (days.length > 3) (days.length * .5).round(),
      if (days.length > 4) (days.length * .75).round(),
      days.length - 1,
    }.where((i) => i >= 0 && i < days.length).toList()
      ..sort();

    final index = value.round();
    if (!indexes.contains(index)) return const SizedBox.shrink();
    final day = days[index];
    return SideTitleWidget(
      axisSide: meta.axisSide,
      space: 10,
      child: Text(
        DateFormat('MMM d').format(day),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurface.withOpacity(.58),
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final incomeSpots = _spots((summary) => summary.income);
    final expenseSpots = _spots((summary) => summary.expense);
    final maxY = _maxY(incomeSpots, expenseSpots);
    final hasData = incomeSpots.any((spot) => spot.y > 0) || expenseSpots.any((spot) => spot.y > 0);
    final maxX = math.max(1.0, (days.length - 1).toDouble());

    return ExpressiveCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Cash Flow Trend',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                ),
              ),
              Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => showDateRangeSheet(context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(.58),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(.16)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          rangeLabel,
                          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                color: Theme.of(context).colorScheme.onSurface.withOpacity(.86),
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(width: 6),
                        Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: Theme.of(context).colorScheme.onSurface.withOpacity(.72)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 230,
            child: hasData
                ? LineChart(
                    LineChartData(
                      minX: 0,
                      maxX: maxX,
                      minY: 0,
                      maxY: maxY,
                      clipData: const FlClipData.all(),
                      lineTouchData: LineTouchData(
                        handleBuiltInTouches: true,
                        touchTooltipData: LineTouchTooltipData(
                          tooltipRoundedRadius: 14,
                          tooltipPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          tooltipMargin: 10,
                          getTooltipColor: (_) => const Color(0xFF122126),
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        horizontalInterval: maxY / 2,
                        getDrawingHorizontalLine: (value) => FlLine(
                          color: Theme.of(context).colorScheme.outline.withOpacity(.18),
                          strokeWidth: 1,
                          dashArray: const [8, 6],
                        ),
                      ),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 46,
                            interval: maxY / 2,
                            getTitlesWidget: (value, meta) => _leftTitle(context, value, meta, maxY),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 30,
                            interval: 1,
                            getTitlesWidget: (value, meta) => _bottomTitle(context, value, meta),
                          ),
                        ),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: incomeSpots,
                          isCurved: true,
                          barWidth: 3.2,
                          color: _incomeColor,
                          isStrokeCapRound: true,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(
                            show: true,
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [_incomeColor.withOpacity(.22), _incomeColor.withOpacity(.02)],
                            ),
                          ),
                        ),
                        LineChartBarData(
                          spots: expenseSpots,
                          isCurved: true,
                          barWidth: 3.2,
                          color: _expenseColor,
                          isStrokeCapRound: true,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(
                            show: true,
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [_expenseColor.withOpacity(.18), _expenseColor.withOpacity(.01)],
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : Center(
                    child: Text(
                      'No chart data exists for this range.',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: kSleekMuted),
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _TrendLegend(color: _incomeColor, label: 'Income'),
              SizedBox(width: 22),
              _TrendLegend(color: _expenseColor, label: 'Expense'),
            ],
          ),
        ],
      ),
    );
  }
}

class _TrendLegend extends StatelessWidget {
  const _TrendLegend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 18,
          height: 6,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(999),
            boxShadow: [BoxShadow(color: color.withOpacity(.35), blurRadius: 8)],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withOpacity(.86),
                fontWeight: FontWeight.w700,
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
            SleekPillSelector<CategoryType>(
              options: const [
                SleekPillOption(value: CategoryType.expense, label: 'Expense', icon: Icons.north_east_rounded),
                SleekPillOption(value: CategoryType.income, label: 'Income', icon: Icons.south_west_rounded),
              ],
              selected: selected,
              onChanged: (v) => setState(() => selected = v),
            ),
            const SizedBox(height: 14),
            CategoryBreakdownCard(type: selected, interactive: true),
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
      child: ResponsiveContent(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (cats.isEmpty)
              EmptyCard(
                icon: Icons.category_rounded,
                title: 'No ${enumName(type)} categories',
                body: 'Tap the + button to create a category.',
              )
            else
              ...cats.map((c) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: CategoryTile(
                      category: c,
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => showCategoryEditor(context, category: c),
                    ),
                  )),
          ],
        ),
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
      Color(0xFF00C7D8),
      Color(0xFF27D17F),
      Color(0xFFFF5353),
      Color(0xFFF59E0B),
      Color(0xFF8B5CF6),
      Color(0xFF38BDF8),
      Color(0xFFF472B6),
      Color(0xFFA3E635),
    ];
    return palette[index % palette.length];
  }

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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExpressiveCard(
          child: SizedBox(
            height: 250,
            child: Stack(
              alignment: Alignment.center,
              children: [
                PieChart(
                  PieChartData(
                    sectionsSpace: 3,
                    centerSpaceRadius: 62,
                    startDegreeOffset: -90,
                    sections: [
                      for (var i = 0; i < entries.length; i++)
                        PieChartSectionData(
                          value: entries[i].value,
                          title: entries[i].value / total >= .08 ? '${((entries[i].value / total) * 100).toStringAsFixed(0)}%' : '',
                          titleStyle: Theme.of(context).textTheme.labelLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w900),
                          radius: 30,
                          color: state.categoryOf(entries[i].key) == null
                              ? _fallbackColor(i)
                              : colorFromHex(state.categoryOf(entries[i].key)!.iconColor, fallback: _fallbackColor(i)),
                        ),
                    ],
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      state.format(total),
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
                    ),
                    Text(
                      'Total',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        ...entries.asMap().entries.map((indexed) {
          final index = indexed.key;
          final entry = indexed.value;
          final category = state.categoryOf(entry.key);
          final color = category == null ? _fallbackColor(index) : colorFromHex(category.iconColor, fallback: _fallbackColor(index));
          final percentage = total <= 0 ? 0.0 : (entry.value / total) * 100;

          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: ExpressiveCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: interactive && category != null
                      ? () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => CategoryTransactionScreen(category: category)),
                          )
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                    child: Row(
                      children: [
                        iconBubble(context, category?.iconName ?? 'category', colorToHex(color), size: 50),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                category?.name ?? 'Unknown',
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
                          state.format(entry.value),
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900),
                        ),
                        if (interactive && category != null) ...[
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
      child: ResponsiveContent(child: Column(children: txs.map((tx) => Padding(padding: const EdgeInsets.only(bottom: 10), child: TransactionTile(tx: tx))).toList())),
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
  await showModalBottomSheet(context: context, isScrollControlled: true, showDragHandle: true, builder: (_) => BudgetEditor(budget: budget));
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
      padding: EdgeInsets.only(left: 18, right: 18, bottom: MediaQuery.of(context).viewInsets.bottom + 18),
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

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final visible = state.loans.where((l) => l.type == type && (completed ? l.isCompleted : !l.isCompleted)).toList();
    final typeLoans = state.loans.where((l) => l.type == type).toList();
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
            SleekPillSelector<LoanType>(
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
            SleekPillSelector<bool>(
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
    final accent = loan.type == LoanType.given ? const Color(0xFFFF7A7A) : const Color(0xFF38BDF8);
    return ExpressiveCard(
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
                  Text(loan.isCompleted ? 'Completed' : 'Open', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: loan.isCompleted ? kSleekIncome : kSleekAccent, fontWeight: FontWeight.w900)),
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
  await showModalBottomSheet(context: context, isScrollControlled: true, showDragHandle: true, builder: (_) => LoanEditor(loan: loan, initialType: initialType));
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
    } else {
      type = widget.initialType;
      accountId = state.defaultAccountId ?? state.accounts.firstOrNull?.id;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    return Padding(
      padding: EdgeInsets.only(left: 18, right: 18, bottom: MediaQuery.of(context).viewInsets.bottom + 18),
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
              option: state.accounts.where((a) => a.id == accountId).firstOrNull == null ? null : optionFromAccount(state.accounts.where((a) => a.id == accountId).first, state),
              emptyText: 'Choose account',
              onTap: () async {
                final selected = await showAppleWheelSelectionSheet(
                  context,
                  title: type == LoanType.given ? 'Choose Paid From Account' : 'Choose Receiving Account',
                  selectedId: accountId,
                  options: state.accounts.map((a) => optionFromAccount(a, state)).toList(),
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
            const SizedBox(height: 18),
            Row(children: [
              if (widget.loan != null) Expanded(child: OutlinedButton(onPressed: () async { await state.deleteLoan(widget.loan!.id); if (context.mounted) Navigator.pop(context); }, child: const Text('Delete'))),
              if (widget.loan != null) const SizedBox(width: 12),
              Expanded(flex: 2, child: FilledButton(onPressed: () async {
                final value = double.tryParse(amount.text) ?? 0;
                if (value <= 0 || person.text.trim().isEmpty || accountId == null) return;
                final now = DateTime.now();
                final loan = Loan(id: widget.loan?.id ?? _uuid.v4(), type: type, accountId: accountId!, personName: person.text.trim(), amount: value, loanDate: loanDate, dueDate: dueDate, notes: notes.text.trim(), repaidAmount: widget.loan?.repaidAmount ?? 0, status: widget.loan?.status ?? LoanStatus.open, createdOn: widget.loan?.createdOn ?? now, updatedOn: now);
                if (widget.loan == null) { await state.addLoan(loan); } else { await state.updateLoan(loan); }
                if (context.mounted) Navigator.pop(context);
              }, child: const Text('Save'))),
            ]),
          ],
        ),
      ),
    );
  }
}

Future<void> showRepaymentEditor(BuildContext context, Loan loan) async {
  await showModalBottomSheet(context: context, isScrollControlled: true, showDragHandle: true, builder: (_) => RepaymentEditor(loan: loan));
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
    return Padding(
      padding: EdgeInsets.only(left: 18, right: 18, bottom: MediaQuery.of(context).viewInsets.bottom + 18),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.loan.type == LoanType.given ? 'Repayment received' : 'Repayment paid', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
          const SizedBox(height: 16),
          TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Repayment amount')),
          const SizedBox(height: 12),
          AppleSelectionField(
            label: widget.loan.type == LoanType.given ? 'Receive repayment into account' : 'Pay repayment from account',
            option: state.accounts.where((a) => a.id == accountId).firstOrNull == null ? null : optionFromAccount(state.accounts.where((a) => a.id == accountId).first, state),
            emptyText: 'Choose account',
            onTap: () async {
              final selected = await showAppleWheelSelectionSheet(
                context,
                title: widget.loan.type == LoanType.given ? 'Choose Receiving Account' : 'Choose Payment Account',
                selectedId: accountId,
                options: state.accounts.map((a) => optionFromAccount(a, state)).toList(),
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
            const _SettingsSearchField(),
            const SizedBox(height: 12),
            SettingsTile(icon: Icons.palette_rounded, title: 'Theme', subtitle: _themeLabel(state.themePreference), color: '#A6E3A1', onTap: () => showThemeDialog(context)),
            SettingsTile(icon: Icons.payments_rounded, title: 'Currency customization', subtitle: '${state.currencyCode} • ${state.currencyPosition == CurrencyPosition.prefix ? 'Prefix' : 'Suffix'}', color: '#78D8E8', onTap: () => showCurrencySheet(context)),
            SettingsTile(icon: Icons.notifications_active_rounded, title: 'Reminder notification', subtitle: state.reminderEnabled ? 'Daily at ${state.reminderTime.format(context)}' : 'Disabled', color: '#FBC879', onTap: () => showReminderSheet(context)),
            SettingsTile(icon: Icons.cloud_sync_rounded, title: 'Online data sync', subtitle: state.cloudSyncStatusText, color: '#78D8E8', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CloudSyncScreen()))),
            SettingsTile(icon: Icons.filter_alt_rounded, title: 'Default date filter', subtitle: _dateRangeLabel(state.dateRangeType), color: '#B4A5FF', onTap: () => showDateRangeSheet(context)),
            SettingsTile(icon: Icons.ios_share_rounded, title: 'Export', subtitle: 'CSV / PDF reports with current filters', color: '#FFB5D0', onTap: () => showExportSheet(context)),
            SettingsTile(icon: Icons.tune_rounded, title: 'Advanced settings', subtitle: 'Defaults, reorder, compact summary, app lock, backup', color: '#9AD0F5', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AdvancedSettingsScreen()))),
            SettingsTile(icon: Icons.info_rounded, title: 'About app', subtitle: 'Version, credits, licenses, and links', color: '#86E3CE', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AboutScreen()))),
          ],
        ),
      ),
    );
  }
}

class _SettingsSearchField extends StatelessWidget {
  const _SettingsSearchField();

  @override
  Widget build(BuildContext context) {
    return TextField(
      readOnly: true,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search_rounded),
        hintText: 'Search settings...',
        filled: true,
        fillColor: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(.52),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
  bool _enabled = false;
  bool _obscurePin = true;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppController>();
    _enabled = state.cloudSyncEnabled;
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
      enabled: _enabled,
      apiBaseUrl: state.cloudSyncApiBaseUrl,
      syncId: _syncIdController.text,
      pin: _pinController.text,
    );
    if (!mounted || !showStatus) return;
    showSnack(context, _enabled ? 'Online sync settings saved.' : 'Online sync disabled.');
  }

  Future<void> _syncNow() async {
    // The main Sync button intentionally uses the same flow as
    // "Download cloud data to this device" so both buttons restore
    // the latest approved cloud snapshot onto this phone.
    await _downloadNow();
  }

  Future<void> _uploadNow() async {
    await _saveSettings(showStatus: false);
    final state = context.read<AppController>();
    await state.syncToCloud(force: true);
    if (!mounted) return;
    await _showSyncResult('Local data uploaded to cloud.');
  }

  Future<void> _downloadNow() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Download cloud data?'),
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
    return PageScaffold(
      title: 'Online data sync',
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
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: kSleekAccent.withOpacity(.15),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Icons.cloud_done_rounded, color: kSleekAccent),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      state.cloudSyncStatusText,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            SwitchListTile(
              value: _enabled,
              onChanged: state.cloudSyncBusy ? null : (value) => setState(() => _enabled = value),
              title: const Text('Enable automatic sync'),
              subtitle: const Text('After local changes, Koinly uploads the latest data automatically.'),
            ),
            const SizedBox(height: 10),
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
              onPressed: state.cloudSyncBusy ? null : _syncNow,
              icon: state.cloudSyncBusy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_sync_rounded),
              label: const Text('Sync'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: state.cloudSyncBusy ? null : _uploadNow,
              icon: const Icon(Icons.cloud_upload_rounded),
              label: const Text('Upload local data now'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: state.cloudSyncBusy ? null : _downloadNow,
              icon: const Icon(Icons.cloud_download_rounded),
              label: const Text('Download cloud data to this device'),
            ),
            const SizedBox(height: 14),
            Text(
              'Important: Download replaces this device’s local data. Create a local backup before downloading if you are not sure. Conflict handling is last-upload-wins.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
            ),
          ],
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

void showThemeDialog(BuildContext context) {
  final state = context.read<AppController>();
  showDialog(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Theme'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: ThemePreference.values.map((t) => RadioListTile<ThemePreference>(title: Text(_themeLabel(t)), value: t, groupValue: state.themePreference, onChanged: (v) async { if (v != null) { await state.saveTheme(v); if (context.mounted) Navigator.pop(context); } })).toList(),
      ),
    ),
  );
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
  showModalBottomSheet(context: context, isScrollControlled: true, showDragHandle: true, builder: (_) => Padding(
        padding: EdgeInsets.only(left: 18, right: 18, bottom: MediaQuery.of(context).viewInsets.bottom + 18),
        child: SingleChildScrollView(
          child: CurrencyForm(initialSymbol: state.currencySymbol, initialCode: state.currencyCode, initialPosition: state.currencyPosition, initialSeparators: state.useSeparators, closeAfterSave: true),
        ),
      ));
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

  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      return StatefulBuilder(
        builder: (context, setModalState) {
          final filtered = filteredCountries();
          if (filtered.isNotEmpty && selectedIndex >= filtered.length) selectedIndex = 0;
          final safeIndex = filtered.isEmpty ? 0 : (selectedIndex < 0 ? 0 : selectedIndex >= filtered.length ? filtered.length - 1 : selectedIndex);
          final selected = filtered.isEmpty ? null : filtered[safeIndex];
          final dark = Theme.of(context).brightness == Brightness.dark;
          final sheetColor = dark ? const Color(0xFF10191D) : Colors.white;
          final innerColor = dark ? const Color(0xFF0B1417) : const Color(0xFFF5FAFB);
          final borderColor = dark ? const Color(0xFF24343A) : const Color(0xFFDCE8EB);
          final innerBorderColor = dark ? const Color(0xFF1F3036) : const Color(0xFFDCE8EB);
          final handleColor = dark ? const Color(0xFF43545B) : const Color(0xFFB7C8CE);

          return SafeArea(
            top: false,
            child: Container(
              margin: const EdgeInsets.all(12),
              padding: EdgeInsets.fromLTRB(16, 10, 16, MediaQuery.of(context).viewInsets.bottom + 16),
              decoration: BoxDecoration(
                color: sheetColor,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: borderColor),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(.45), blurRadius: 28, offset: const Offset(0, -8))],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(color: handleColor, borderRadius: BorderRadius.circular(999)),
                  ),
                  const SizedBox(height: 18),
                  Text('Choose currency', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900)),
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
                              style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w700),
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
                                  style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900),
                                ),
                              ),
                              Text(
                                '${selected[1]} • ${selected[2]}',
                                style: Theme.of(context).textTheme.labelMedium?.copyWith(color: kSleekMuted, fontWeight: FontWeight.w800),
                              ),
                            ],
                          ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(sheetContext), child: const Text('Cancel'))),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: FilledButton(
                          onPressed: selected == null ? null : () => Navigator.pop(sheetContext, selected),
                          child: const Text('Done'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
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
  showModalBottomSheet(context: context, showDragHandle: true, builder: (_) => const ReminderSheet());
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
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
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
  showModalBottomSheet(context: context, showDragHandle: true, builder: (_) => const ExportSheet());
}

class ExportSheet extends StatelessWidget {
  const ExportSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppController>();
    final txs = state.filteredTransactions();
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
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
          SwitchListTile(value: state.compactHomeSummary, onChanged: state.setCompactHome, title: const Text('Compact home summary'), subtitle: const Text('Use a shorter dashboard summary card.')),
          SwitchListTile(value: state.appLockEnabled, onChanged: state.setAppLock, title: const Text('App lock'), subtitle: const Text('Uses fingerprint or device PIN/password when available.')),
          SettingsTile(icon: Icons.backup_rounded, title: 'Backup', color: '#86E3CE', onTap: () => runBackupFlow(context, state)),
          SettingsTile(icon: Icons.restore_rounded, title: 'Restore', color: '#B4A5FF', onTap: () => runRestoreFlow(context, state)),
        ]),
      ),
    );
  }
}

void showDefaultSelection(BuildContext context, String mode) {
  final state = context.read<AppController>();
  showModalBottomSheet(context: context, showDragHandle: true, builder: (_) {
    final items = mode == 'account' ? state.accounts : state.categories.where((c) => c.type == (mode == 'income' ? CategoryType.income : CategoryType.expense) && !c.isLoanSystemCategory).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('Choose default', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
        ...items.map((item) {
          if (item is Account) return ListTile(title: Text(item.name), onTap: () async { await state.saveDefaults(accountId: item.id); if (context.mounted) Navigator.pop(context); });
          final c = item as Category;
          return ListTile(title: Text(c.name), onTap: () async { await state.saveDefaults(incomeCategoryId: mode == 'income' ? c.id : null, expenseCategoryId: mode == 'expense' ? c.id : null); if (context.mounted) Navigator.pop(context); });
        }),
      ]),
    );
  });
}

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const links = [
    ('Telegram', Icons.chat_rounded, 'https://t.me/Ch0wdhury_Siam'),
    ('Telegram Alternative', Icons.forum_rounded, 'https://t.me/Chowdhury_Siam'),
    ('GitHub', Icons.code_rounded, 'https://github.com/Chowdhury-Siam'),
    ('MyAnimeList', Icons.movie_filter_rounded, 'https://myanimelist.net/profile/Siam_Chowdhury'),
    ('AniList', Icons.auto_awesome_rounded, 'https://anilist.co/user/SiamChowdhury/'),
    ('YouTube', Icons.play_circle_rounded, 'https://www.youtube.com/@SCS_Otaku'),
    ('X / Twitter', Icons.alternate_email_rounded, 'https://x.com/SiamChowdhuryy'),
    ('Email', Icons.mail_rounded, 'mailto:ssiam4235@gmail.com'),
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
                const Text('Version: 1.0.0', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: links.map((l) => IconButton.filledTonal(tooltip: l.$1, icon: Icon(l.$2), onPressed: () => launchUrl(Uri.parse(l.$3), mode: LaunchMode.externalApplication))).toList()),
              ]),
            ),
            const SectionHeader('Legal'),
            SettingsTile(icon: Icons.privacy_tip_rounded, title: 'Privacy Policy', subtitle: 'Local data-first finance tracker', color: '#78D8E8', onTap: () => _showLegal(context, 'Privacy Policy')),
            SettingsTile(icon: Icons.description_rounded, title: 'Terms and conditions', subtitle: 'Usage terms', color: '#A6E3A1', onTap: () => _showLegal(context, 'Terms and conditions')),
            SettingsTile(icon: Icons.balance_rounded, title: 'Open-source licenses', subtitle: 'Apache License 2.0 and Flutter package notices', color: '#FBC879', onTap: () => showLicensePage(context: context, applicationName: appTitle, applicationVersion: appVersion)),
          ],
        ),
      ),
    );
  }

  void _showLegal(BuildContext context, String title) {
    showDialog(context: context, builder: (_) => AlertDialog(title: Text(title), content: const Text('This Flutter rebuild keeps the original local-first behavior. Replace this placeholder with the production policy text used by the Kotlin release.'), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))]));
  }
}
