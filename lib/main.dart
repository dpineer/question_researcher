// ==========================================
// AI 助教老师 - 双引擎互动出题与学情分析系统 (Linux Desktop)
// ==========================================

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math; // 用于处理向量相似度计算中的数学函数
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // 用于粘贴板复制功能
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as path;
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';

//[新增] Markdown与Latex渲染依赖
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_markdown_plus_latex/flutter_markdown_plus_latex.dart';
import 'package:markdown/markdown.dart' as md;

// ==========================================
// 附加服务：全局业务日志总线 (替代底层 tail)
// ==========================================
class AppLogger {
  static final StreamController<String> _controller = StreamController<String>.broadcast();
  static Stream<String> get stream => _controller.stream;

  static void log(String message, {bool isError = false}) {
    final timestamp = DateTime.now().toString().substring(11, 19); // 获取 HH:mm:ss
    final prefix = isError ? "[ERROR]" : "[INFO]";
    final logLine = "$prefix [$timestamp] $message";
    _controller.add(logLine);
    debugPrint(logLine);
  }
}

// ==========================================
// 附加视图层 - 知识库专属 Q&A 问答交互界面
// ==========================================
class ChatMessage {
  final String role; // 'user' or 'ai'
  final String text;
  ChatMessage({required this.role, required this.text});
}

class ChatWithKnowledgeScreen extends StatefulWidget {
  final SavedExam exam;
  const ChatWithKnowledgeScreen({super.key, required this.exam});

  @override
  State<ChatWithKnowledgeScreen> createState() => _ChatWithKnowledgeScreenState();
}

class _ChatWithKnowledgeScreenState extends State<ChatWithKnowledgeScreen> {
  final List<ChatMessage> _messages = [];
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  
  bool _isReplying = false;
  bool _isGeneratingDAG = false;

  @override
  void initState() {
    super.initState();
    _messages.add(ChatMessage(
      role: 'ai', 
      text: "您好！我是您的 AI 助教。我已经阅读了题库 **【${widget.exam.title}】** 的所有知识源。有什么关于这部分内容的问题需要和我探讨吗？"
    ));
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _chatController.text.trim();
    if (text.isEmpty || _isReplying) return;

    setState(() {
      _messages.add(ChatMessage(role: 'user', text: text));
      _isReplying = true;
      _chatController.clear();
    });
    _scrollToBottom();

    // 1. 进行 RAG 知识检索获取上下文
    String relevantContext = widget.exam.knowledgeBase;
    final embeddingModel = await ConfigService.getEmbeddingModel();
    final lmUrl = await ConfigService.getLmStudioUrl();
    
    if (embeddingModel.isNotEmpty && relevantContext.length > 600) {
      AppLogger.log("Q&A 触发语义检索...");
      relevantContext = await SemanticRetrievalService.getRelevantContext(
        widget.exam.knowledgeBase, text, embeddingModel, lmUrl,
      );
    }

    // 2. 调用大模型回答
    String aiResponse = await DualAIService.answerQuestionWithContext(text, relevantContext);

    if (mounted) {
      setState(() {
        _messages.add(ChatMessage(role: 'ai', text: aiResponse));
        _isReplying = false;
      });
      _scrollToBottom();
    }
  }

  // --- [迁移集成] DAG 辅助理解生成系统 ---
  Future<void> _generateDAG() async {
    final text = widget.exam.knowledgeBase.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("知识库为空")));
      return;
    }

    setState(() => _isGeneratingDAG = true);
    final dagCode = await DualAIService.generateKnowledgeDAG(text);
    setState(() => _isGeneratingDAG = false);
    
    if (mounted) _showDAGDialog(dagCode);
  }

  void _showDAGDialog(String dagCode) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.account_tree, color: Colors.blue),
            const SizedBox(width: 8),
            const Text("知识图谱 DAG (Mermaid)"),
          ],
        ),
        content: SizedBox(
          width: 600, height: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("已为您抽取出关键信息的逻辑化有向无环图，您可以复制代码并在任意支持 Mermaid 的渲染器中查看：", style: TextStyle(fontSize: 13, color: Colors.grey)),
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  width: double.infinity, padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceVariant, borderRadius: BorderRadius.circular(8)),
                  child: SingleChildScrollView(child: SelectableText(dagCode, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy), label: const Text("复制代码"),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: dagCode));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("DAG 代码已复制到剪贴板")));
            },
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text("关闭"))
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("探讨：${widget.exam.title}"),
        actions: [
          // DAG 功能已微缩至此处为快捷小图标
          _isGeneratingDAG
            ? const Center(child: Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))))
            : IconButton(
                icon: const Icon(Icons.account_tree, color: Colors.blueAccent),
                tooltip: "一键抽取逻辑 DAG 图",
                onPressed: _generateDAG,
              ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                final isUser = msg.role == 'user';
                return Container(
                  margin: const EdgeInsets.only(bottom: 24),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
                    children: [
                      if (!isUser) ...[
                        const CircleAvatar(backgroundColor: Colors.indigo, child: Icon(Icons.smart_toy, color: Colors.white, size: 20)),
                        const SizedBox(width: 12),
                      ],
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: isUser ? Theme.of(context).colorScheme.primaryContainer : Theme.of(context).colorScheme.surfaceVariant,
                            borderRadius: BorderRadius.only(
                              topLeft: const Radius.circular(16),
                              topRight: const Radius.circular(16),
                              bottomLeft: Radius.circular(isUser ? 16 : 0),
                              bottomRight: Radius.circular(isUser ? 0 : 16),
                            ),
                          ),
                          // 核心：使用 Markdown 引擎渲染回复
                          child: _renderMarkdown(msg.text, isSelectable: true, shrinkWrap: true),
                        ),
                      ),
                      if (isUser) ...[
                        const SizedBox(width: 12),
                        CircleAvatar(backgroundColor: Colors.grey.shade400, child: const Icon(Icons.person, color: Colors.white, size: 20)),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
          if (_isReplying)
            const Padding(
              padding: EdgeInsets.all(8.0),
              child: Text("AI 导师正在查阅资料并思考...", style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic)),
            ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _chatController,
                    maxLines: 3, minLines: 1,
                    decoration: const InputDecoration(hintText: "就当前知识库提出疑问...", border: OutlineInputBorder()),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _isReplying ? null : _sendMessage,
                  style: FilledButton.styleFrom(shape: const CircleBorder(), padding: const EdgeInsets.all(16)),
                  child: const Icon(Icons.send),
                )
              ],
            ),
          )
        ],
      ),
    );
  }
}
// ==========================================
// 附加服务：Markdown与LaTeX动态渲染器
// ==========================================
String _preprocessLatex(String text) {
  if (text.isEmpty) return "正在检索知识库...";
  // 标准化 LaTeX 块级与行内符号边界
  return text
      .replaceAll(r'\[', r'$$')
      .replaceAll(r'\]', r'$$')
      .replaceAll(r'\(', r'$')
      .replaceAll(r'\)', r'$');
}

Widget _renderMarkdown(String content, {bool isSelectable = false, bool shrinkWrap = true}) {
  final processedContent = _preprocessLatex(content);
  return MarkdownBody(
    data: processedContent,
    selectable: isSelectable,
    shrinkWrap: shrinkWrap,
    builders: {
      'latex': LatexElementBuilder(
        textStyle: const TextStyle(fontWeight: FontWeight.w400, fontSize: 16.0),
      ),
    },
    extensionSet: md.ExtensionSet([...md.ExtensionSet.gitHubFlavored.blockSyntaxes, LatexBlockSyntax()],[...md.ExtensionSet.gitHubFlavored.inlineSyntaxes, LatexInlineSyntax()],
    ),
  );
}

// ==========================================
// 0. 初始化与入口
// ==========================================
void initializeDatabase() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initializeDatabase();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers:[
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => ExamProvider()),
        ChangeNotifierProvider(create: (_) => ExamTakingProvider()),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, child) {
          return MaterialApp(
            title: 'AI 互动助教',
            themeMode: themeProvider.themeMode,
            theme: ThemeData(useMaterial3: true, brightness: Brightness.light, colorSchemeSeed: Colors.indigo),
            darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark, colorSchemeSeed: Colors.indigo),
            home: const HomeScreen(),
            debugShowCheckedModeBanner: false,
          );
        },
      ),
    );
  }
}

// ==========================================
// 1. 状态管理 - 全局主题与配置
// ==========================================
class ThemeProvider extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  ThemeProvider() { _loadTheme(); }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final themeString = prefs.getString('theme_mode') ?? 'system';
    _themeMode = ThemeMode.values.firstWhere(
      (e) => e.toString().split('.')[1] == themeString, 
      orElse: () => ThemeMode.system
    );
    notifyListeners();
  }

  Future<void> toggleTheme(bool isDark) async {
    _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', _themeMode.toString().split('.')[1]);
  }
}

class ConfigService {
  static const _storage = FlutterSecureStorage();
  
  static Future<String> getDeepSeekKey() async => await _storage.read(key: "deepseek_key") ?? "";
  static Future<void> saveDeepSeekKey(String key) async => await _storage.write(key: "deepseek_key", value: key);

  static Future<String> getLmStudioUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString("lm_studio_url") ?? "http://localhost:1234/v1";
  }
  static Future<void> saveLmStudioUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("lm_studio_url", url);
  }

  // ==== 新增：动态模型标识配置 ====
  static Future<String> getChatModel() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString("lm_chat_model") ?? "local-model";
  }
  static Future<void> saveChatModel(String model) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("lm_chat_model", model);
  }

  static Future<String> getVisionModel() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString("lm_vision_model") ?? "vision-model";
  }
  static Future<void> saveVisionModel(String model) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("lm_vision_model", model);
  }

  static Future<String> getRerankModel() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString("lm_rerank_model") ?? "";
  }
  static Future<void> saveRerankModel(String model) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("lm_rerank_model", model);
  }

  static Future<String> getEmbeddingModel() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString("lm_embedding_model") ?? "";
  }
  static Future<void> saveEmbeddingModel(String model) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("lm_embedding_model", model);
  }

  // 新增：获取是否启用rerank功能
  static Future<bool> getEnableRerank() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool("enable_rerank") ?? false;
  }
  
  static Future<void> setEnableRerank(bool enable) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool("enable_rerank", enable);
  }
}

// ==========================================
// 2. 数据层 - 实体模型 (支持多题型与作答记录)
// ==========================================
class ExamQuestion {
  final String type; // single_choice, multi_choice, fill_blank, essay
  final String question;
  final List<String> options;
  final dynamic correctAnswer; // String, List<dynamic>, or keyword criteria
  final String analysis;

  ExamQuestion({
    required this.type,
    required this.question,
    required this.options,
    required this.correctAnswer,
    required this.analysis,
  });

  factory ExamQuestion.fromJson(Map<String, dynamic> json) => ExamQuestion(
    type: json['type'] ?? 'single_choice',
    question: json['question'] ?? '',
    options: List<String>.from(json['options'] ?? []),
    correctAnswer: json['correct_answer'],
    analysis: json['analysis'] ?? '',
  );

  Map<String, dynamic> toJson() => {
    'type': type,
    'question': question,
    'options': options,
    'correct_answer': correctAnswer,
    'analysis': analysis,
  };
}

class SavedExam {
  final int? id;
  final String title;
  final String examJson; 
  final String knowledgeBase; // 新增：保存原始上下文，用于刷新题目
  final int createdAt;

  SavedExam({this.id, required this.title, required this.examJson, this.knowledgeBase = "", required this.createdAt});

  Map<String, dynamic> toMap() => {
    'id': id, 'title': title, 'examJson': examJson, 'knowledgeBase': knowledgeBase, 'createdAt': createdAt,
  };

  factory SavedExam.fromMap(Map<String, dynamic> map) => SavedExam(
    id: map['id'] as int?,
    title: map['title'] as String,
    examJson: map['examJson'] as String,
    knowledgeBase: map['knowledgeBase'] as String? ?? "", // 兼容老数据
    createdAt: map['createdAt'] as int,
  );

  List<ExamQuestion> get parsedQuestions {
    final list = jsonDecode(examJson) as List;
    return list.map((e) => ExamQuestion.fromJson(e)).toList();
  }
}

class ExamRecord {
  final int? id;
  final int examId;
  final String userAnswersJson;
  final String aiFeedbackJson;
  final int score;
  final int createdAt;

  ExamRecord({this.id, required this.examId, required this.userAnswersJson, required this.aiFeedbackJson, required this.score, required this.createdAt});

  Map<String, dynamic> toMap() => {
    'id': id, 'examId': examId, 'userAnswersJson': userAnswersJson, 'aiFeedbackJson': aiFeedbackJson, 'score': score, 'createdAt': createdAt,
  };

  factory ExamRecord.fromMap(Map<String, dynamic> map) => ExamRecord(
    id: map['id'] as int?,
    examId: map['examId'] as int,
    userAnswersJson: map['userAnswersJson'] as String,
    aiFeedbackJson: map['aiFeedbackJson'] as String,
    score: map['score'] as int,
    createdAt: map['createdAt'] as int,
  );

  Map<String, dynamic> get parsedAnswers => jsonDecode(userAnswersJson);
  Map<String, dynamic> get parsedFeedbacks => jsonDecode(aiFeedbackJson);
}

// ==========================================
// 3. 数据层 - SQLite 数据库
// ==========================================
class DatabaseHelper {
  static Database? _database;
  static Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB();
    return _database!;
  }

  static Future<Database> _initDB() async {
    final docDir = io.Directory('${io.Platform.environment['HOME']}/.ai_teacher');
    if (!await docDir.exists()) await docDir.create(recursive: true);
    String dbPath = path.join(docDir.path, 'exams_v2.db'); 
    
    // 版本升级至 2，支持历史数据热迁移
    return await openDatabase(dbPath, version: 2, onCreate: (db, version) async {
      await db.execute('''
        CREATE TABLE saved_exams (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          examJson TEXT NOT NULL,
          knowledgeBase TEXT NOT NULL,
          createdAt INTEGER NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE exam_records (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          examId INTEGER NOT NULL,
          score INTEGER NOT NULL,
          userAnswersJson TEXT NOT NULL,
          aiFeedbackJson TEXT NOT NULL,
          createdAt INTEGER NOT NULL,
          FOREIGN KEY (examId) REFERENCES saved_exams (id) ON DELETE CASCADE
        )
      ''');
    }, onUpgrade: (db, oldVersion, newVersion) async {
      if (oldVersion < 2) {
        // V1 到 V2 升级，追加知识库列
        await db.execute('ALTER TABLE saved_exams ADD COLUMN knowledgeBase TEXT DEFAULT ""');
      }
    });
  }

  static Future<int> saveExam(SavedExam exam) async {
    final db = await database;
    return await db.insert('saved_exams', exam.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<List<SavedExam>> getAllExams() async {
    final db = await database;
    final maps = await db.query('saved_exams', orderBy: 'createdAt DESC');
    return maps.map((m) => SavedExam.fromMap(m)).toList();
  }

  static Future<void> saveExamRecord(ExamRecord record) async {
    final db = await database;
    await db.insert('exam_records', record.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<List<ExamRecord>> getRecordsForExam(int examId) async {
    final db = await database;
    final maps = await db.query('exam_records', where: 'examId = ?', whereArgs: [examId], orderBy: 'createdAt DESC');
    return maps.map((m) => ExamRecord.fromMap(m)).toList();
  }

  static Future<void> deleteExam(int id) async {
    final db = await database;
    await db.delete('saved_exams', where: 'id = ?', whereArgs: [id]);
  }

  /// 更新已保存的测验数据（主要用于修改知识库原始文本）
  static Future<int> updateExam(SavedExam exam) async {
    final db = await database;
    return await db.update(
      'saved_exams',
      exam.toMap(),
      where: 'id = ?',
      whereArgs: [exam.id],
    );
  }
}

// ==========================================
// 4. 服务层 - 双模型 AI 流水线 (包含埋点与防超时)
// ==========================================
class DualAIService {
  static final Dio _dio = Dio();

  static String _cleanJson(String raw) {
    return raw.replaceAll(RegExp(r'^```json\s*|^```\s*', multiLine: true), '').replaceAll(RegExp(r'```$'), '').trim();
  }

  static Future<String> _rerankContent(String context) async {
    final enableRerank = await ConfigService.getEnableRerank();
    if (!enableRerank) return context;
    
    final rerankModel = await ConfigService.getRerankModel();
    if (rerankModel.isEmpty) return context;
    
    AppLogger.log("启动 Rerank 优化模型：正在剥离无关噪声...");
    final localUrl = await ConfigService.getLmStudioUrl();
    try {
      final response = await _dio.post(
        '$localUrl/chat/completions',
        options: Options(receiveTimeout: const Duration(minutes: 5)), // 放宽超时限制
        data: {
          "model": rerankModel, 
          "messages":[
            {"role": "system", "content": "你是一个文本重排序专家。请对输入的文本进行重新排序，将最重要的内容放在前面，按重要性递减的顺序排列。"},
            {"role": "user", "content": "请对以下文本进行重排序：\n\n文本：$context"}
          ],
          "temperature": 0.1,
        },
      );
      final usage = response.data['usage'];
      AppLogger.log("Rerank 处理完毕，消耗 Tokens: [Prompt: ${usage?['prompt_tokens']}, Completion: ${usage?['completion_tokens']}]");
      return response.data['choices'][0]['message']['content'];
    } catch (e) {
      AppLogger.log("Rerank 模型返回异常，回退至原始内容", isError: true);
      return context; 
    }
  }

  static Future<String> _draftIdeasLocally(String context, int count) async {
    String processedContext = await _rerankContent(context);
    
    AppLogger.log("调用本地基座模型提炼考点灵感...");
    final localUrl = await ConfigService.getLmStudioUrl();
    final chatModel = await ConfigService.getChatModel(); 
    try {
      final response = await _dio.post(
        '$localUrl/chat/completions',
        options: Options(receiveTimeout: const Duration(minutes: 10)), // 彻底解决复杂文本导致的前端假死断开
        data: {
          "model": chatModel, 
          "messages":[
            {"role": "system", "content": "你是一个学术助教。请从庞杂的用户数据中，提取出最具考察价值的知识点。"},
            {"role": "user", "content": "请基于以下文本，列出 $count 个适合作为考试题目的知识点：\n\n文本：$processedContext"}
          ],
          "temperature": 0.3,
        },
      );
      final usage = response.data['usage'];
      AppLogger.log("本地考点提炼成功，消耗 Tokens: [Prompt: ${usage?['prompt_tokens']}, Completion: ${usage?['completion_tokens']}]");
      return response.data['choices'][0]['message']['content'];
    } catch (e) {
      AppLogger.log("本地提炼请求失败，改为云端直连: $e", isError: true);
      return "（本地提取失败，请直接依据原文理解）\n$processedContext";
    }
  }

  static Future<Map<String, dynamic>> generateMixedExam({
    required String contextText, required String topic, required int count, required String difficulty,
  }) async {
    final apiKey = await ConfigService.getDeepSeekKey();
    if (apiKey.isEmpty) {
      AppLogger.log("未配置云端 DeepSeek API Key", isError: true);
      return {"error": "未配置云端验证模型 (DeepSeek) API Key"};
    }

    String draftedIdeas = await _draftIdeasLocally(contextText, count);

    AppLogger.log("向云端大模型 (DeepSeek) 请求最终 JSON 混合题型构建...");
    // 省略 Prompt 构造部分（保持原有逻辑）
    final prompt = """你是一个资深的学科出题专家。请基于以下提供的【本地助教出题灵感】和【原始上下文资料】，针对主题【$topic】，生成一份高质量的混合题型试卷。
出题严格要求：
1. 题量：$count 道。难度：$difficulty。
2. 题型分布：必须包含单选(single_choice)、多选(multi_choice)、填空(fill_blank)、应用题(essay)。
3. 重点考察：不要直接考文档中的具体代码实现，而是考察对概念、思路、框架、架构设计的理解和应用。
【出题灵感】：\n$draftedIdeas\n【原始上下文】：\n$contextText
必须以严格 JSON 格式返回：{"questions":[{"type": "single_choice", "question": "题干", "options":["A", "B", "C", "D"], "correct_answer": "正确答案", "analysis": "详细解析"}]}""";

    try {
      final response = await _dio.post(
        "https://api.deepseek.com/v1/chat/completions",
        options: Options(
          headers: {"Authorization": "Bearer $apiKey", "Content-Type": "application/json"},
          receiveTimeout: const Duration(minutes: 5),
        ),
        data: {
          "model": "deepseek-chat",
          "messages":[
            {"role": "system", "content": "你是一个严格的 JSON 出题机器。禁止输出任何非 JSON 格式的内容。"},
            {"role": "user", "content": prompt}
          ],
          "temperature": 0.3,
        },
      );
      final usage = response.data['usage'];
      AppLogger.log("云端试卷构建成功！云端消耗 Tokens:[Prompt: ${usage?['prompt_tokens']}, Completion: ${usage?['completion_tokens']}]");
      
      String content = response.data['choices'][0]['message']['content'];
      return jsonDecode(_cleanJson(content));
    } catch (e) {
      AppLogger.log("云端出题请求异常: $e", isError: true);
      return {"error": "API 请求异常: $e"};
    }
  }

  // --- OCR 与评估方法由于类似，我只写关键埋点 ---
  static Future<String> performLocalOCR(String filePath, {int maxRetries = 3}) async {
    final localUrl = await ConfigService.getLmStudioUrl();
    final visionModel = await ConfigService.getVisionModel();
    AppLogger.log("触发视觉处理模型，正在解析: ${path.basename(filePath)}");

    final bytes = await io.File(filePath).readAsBytes();
    final base64Img = base64Encode(bytes);
    final mimeType = path.extension(filePath).toLowerCase() == '.png' ? 'image/png' : 'image/jpeg';

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final response = await _dio.post(
          '$localUrl/chat/completions',
          options: Options(receiveTimeout: const Duration(minutes: 5), validateStatus: (s) => s != null && s < 600),
          data: {
            "model": visionModel, 
            "messages":[{"role": "user", "content":[{"type": "text", "text": "提取图片中的所有文本信息。"},{"type": "image_url", "image_url": {"url": "data:$mimeType;base64,$base64Img"}}]}]
          },
        );
        if (response.statusCode != 200) throw Exception("HTTP ${response.statusCode}: ${response.data}");
        
        final usage = response.data['usage'];
        AppLogger.log("视觉解析成功: ${path.basename(filePath)} [消耗 Tokens: ${usage?['completion_tokens']}]");
        return response.data['choices'][0]['message']['content'];
      } catch (e) {
        AppLogger.log("OCR 第 $attempt 次尝试失败: $e", isError: true);
        if (attempt == maxRetries) throw Exception("视觉服务重试耗尽");
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }
    return "";
  }

  /// 阶段三：针对考生特定回答进行形成性分析 (云端大模型)
  static Future<String> evaluateUserAnswer(ExamQuestion q, dynamic userAnswer) async {
    final apiKey = await ConfigService.getDeepSeekKey();
    if (apiKey.isEmpty) return "AI 评价服务未就绪";

    final prompt = """
你是一个 AI 学情分析导师。请对学生的答题情况进行诊断。
题型：${q.type}
题目：${q.question}
标准答案/采分点：${jsonEncode(q.correctAnswer)}
题目解析：${q.analysis}

考生的回答是：${jsonEncode(userAnswer)}

请判断考生的掌握情况，并用简短、鼓励的语气给出针对性的诊断（约50-100字）。如果考生答错，请一针见血地指出其思维误区；如果是一道主观题（essay），请指出其回答的亮点与缺失的采分点。不要返回 JSON，直接返回文本评语。
""";

    try {
      final response = await _dio.post(
        "https://api.deepseek.com/v1/chat/completions",
        options: Options(headers: {"Authorization": "Bearer $apiKey", "Content-Type": "application/json"}),
        data: {
          "model": "deepseek-chat",
          "messages":[{"role": "user", "content": prompt}],
          "temperature": 0.2,
        },
      );
      return response.data['choices'][0]['message']['content'].toString().trim();
    } catch (e) {
      return "诊断生成失败，请参考标准答案进行自纠。";
    }
  }

  /// 新增：基于持久化的历史记录，生成个性化指导
  static Future<String> generatePersonalizedGuidance(String examTitle, List<ExamRecord> records, List<ExamQuestion> questions) async {
    final apiKey = await ConfigService.getDeepSeekKey();
    if (apiKey.isEmpty) return "未配置云端 API Key";

    // 提取所有错题和历史反馈日志以压缩 prompt
    List<Map<String, dynamic>> errorLogs =[];
    for (var rec in records) {
      final feedbacks = rec.parsedFeedbacks;
      feedbacks.forEach((idxStr, feedback) {
        if (!feedback.toString().contains("完全正确")) {
          int idx = int.parse(idxStr);
          errorLogs.add({"question": questions[idx].question, "ai_diagnosis": feedback});
        }
      });
    }

    final prompt = """
你是一个 AI 学情规划师。以下是学生在题库【$examTitle】中的历史易错点诊断汇总：
${jsonEncode(errorLogs)}

请根据这些错题的诊断规律，生成一份结构化的个性化复习指导（控制在300字以内），明确指出该考生的薄弱知识域，并提供实用的学习建议。
""";

    try {
      final response = await _dio.post(
        "https://api.deepseek.com/v1/chat/completions",
        options: Options(headers: {"Authorization": "Bearer $apiKey", "Content-Type": "application/json"}),
        data: {"model": "deepseek-chat", "messages":[{"role": "user", "content": prompt}], "temperature": 0.4},
      );
      return response.data['choices'][0]['message']['content'];
    } catch (e) {
      return "个性化指导生成失败。";
    }
  }

  /// 生成用于辅助理解的 DAG 图 (基于 Mermaid graph TD 语法)
  static Future<String> generateKnowledgeDAG(String contextText) async {
    final apiKey = await ConfigService.getDeepSeekKey();
    if (apiKey.isEmpty) {
      AppLogger.log("DAG 生成失败: 未配置云端 API Key", isError: true);
      return "错误: 未配置云端 API Key";
    }

    final prompt = """
你是一个数据结构化图谱专家。请基于以下【原始文本】，提取核心业务概念、实体及其内在逻辑关联，生成一个用于辅助理解的 DAG（有向无环图）。
要求：
1. 严格按照 Mermaid 的 graph TD 语法输出。
2. 节点命名需简明扼要，连接线可包含动作语义。
3. 禁止输出任何非 Mermaid 格式的无关解释文本。

【原始文本】：
$contextText
""";

    AppLogger.log("向云端大模型请求生成知识结构 DAG 图...");

    try {
      final response = await _dio.post(
        "https://api.deepseek.com/v1/chat/completions",
        options: Options(
          headers: {"Authorization": "Bearer $apiKey", "Content-Type": "application/json"},
          receiveTimeout: const Duration(minutes: 3),
        ),
        data: {
          "model": "deepseek-chat",
          "messages":[
            {"role": "system", "content": "你是一个严格的 Mermaid DAG 代码生成器。"},
            {"role": "user", "content": prompt}
          ],
          "temperature": 0.2,
        },
      );
      
      String content = response.data['choices'][0]['message']['content'];
      // 清理 Markdown 标记，仅保留纯粹的 Mermaid DSL
      return content.replaceAll(RegExp(r'^```mermaid\s*|^```\s*', multiLine: true), '').replaceAll(RegExp(r'```$'), '').trim();
    } catch (e) {
      AppLogger.log("DAG 生成请求异常: $e", isError: true);
      return "DAG 生成异常: $e";
    }
  }

  /// [新增] 基于本地提取上下文的 Q&A 问答生成 (云端大模型)
  static Future<String> answerQuestionWithContext(String question, String contextText) async {
    final apiKey = await ConfigService.getDeepSeekKey();
    if (apiKey.isEmpty) return "错误: 未配置云端 API Key";

    final prompt = """
你是一个严谨的学术助教。请基于以下提供的【知识库检索上下文】回答用户的问题。
要求：
1. 答案必须准确、精炼，并使用 Markdown 格式排版。
2. 如果【知识库检索上下文】中没有涵盖相关信息，请明确告知"资料中未提及相关内容"，绝对禁止伪造事实或凭空捏造。

【知识库检索上下文】：
$contextText

【用户提问】：
$question
""";

    AppLogger.log("启动知识库定向问答，请求大模型进行思考...");

    try {
      final response = await _dio.post(
        "https://api.deepseek.com/v1/chat/completions",
        options: Options(
          headers: {"Authorization": "Bearer $apiKey", "Content-Type": "application/json"},
          receiveTimeout: const Duration(minutes: 3),
        ),
        data: {
          "model": "deepseek-chat",
          "messages": [
            {"role": "system", "content": "你是一个严格遵循所提供资料的问答助手。"},
            {"role": "user", "content": prompt}
          ],
          "temperature": 0.2, // 保持低随机性以确保事实准确
        },
      );
      
      final usage = response.data['usage'];
      AppLogger.log("问答响应成功！消耗 Tokens:[Prompt: ${usage?['prompt_tokens']}, Completion: ${usage?['completion_tokens']}]");
      return response.data['choices'][0]['message']['content'].toString().trim();
    } catch (e) {
      AppLogger.log("问答请求异常: $e", isError: true);
      return "问答请求异常: $e";
    }
  }
}

// ==========================================
// 4. 服务层 - 附加轻量级向量检索服务 (修复版)
// ==========================================
class SemanticRetrievalService {
  static final Dio _dio = Dio();

  static List<String> _chunkText(String text, {int chunkSize = 600, int overlap = 100}) {
    if (text.length <= chunkSize) return [text];
    List<String> chunks =[];
    int start = 0;
    while (start < text.length) {
      int end = start + chunkSize;
      if (end > text.length) end = text.length;
      chunks.add(text.substring(start, end));
      start += (chunkSize - overlap);
    }
    return chunks;
  }

  static double _cosineSimilarity(List<double> v1, List<double> v2) {
    double dotProduct = 0.0, normA = 0.0, normB = 0.0;
    for (int i = 0; i < v1.length; i++) {
      dotProduct += v1[i] * v2[i];
      normA += v1[i] * v1[i];
      normB += v2[i] * v2[i];
    }
    if (normA == 0 || normB == 0) return 0.0;
    return dotProduct / (math.sqrt(normA) * math.sqrt(normB));
  }

  /// 修复版 RAG 检索：采用串行处理切片以适应本地小模型，并实时回传进度
  static Future<String> getRelevantContext(
    String rawText, 
    String query, 
    String model, 
    String baseUrl,
    {Function(String status, double progress)? onProgress}
  ) async {
    if (model.isEmpty) return rawText;

    onProgress?.call("正在进行文本语义分块 (Chunking)...", 0.05);
    // 降低 chunk 尺寸以确保绝不会超出 2048 token 的小模型限制
    final chunks = _chunkText(rawText, chunkSize: 600, overlap: 100);
    AppLogger.log("文本已切分为 ${chunks.length} 个切片");

    List<List<double>> chunkEmbeddings =[];
    
    // 采用串行逐一请求代替批量请求，解决本地模型不支持 Batching 的问题
    for (int i = 0; i < chunks.length; i++) {
      onProgress?.call("本地 Embedding 向量化: 第 ${i + 1}/${chunks.length} 块", 0.05 + 0.8 * (i / chunks.length));
      try {
        final response = await _dio.post(
          '$baseUrl/embeddings',
          data: {"model": model, "input": chunks[i]}, // 单个 String 而非 List
          options: Options(receiveTimeout: const Duration(seconds: 30)),
        );
        chunkEmbeddings.add(List<double>.from(response.data['data'][0]['embedding']));
      } catch (e) {
        AppLogger.log("第 $i 块 Embedding 失败: $e", isError: true);
        // 如果出错，注入一个空的占位向量防止后续对齐奔溃
        chunkEmbeddings.add(List<double>.filled(1536, 0.0)); 
      }
    }

    onProgress?.call("正在生成用户主题的参考向量...", 0.90);
    List<double> queryVector =[];
    try {
      final qRes = await _dio.post('$baseUrl/embeddings', data: {"model": model, "input": query});
      queryVector = List<double>.from(qRes.data['data'][0]['embedding']);
    } catch (e) {
      AppLogger.log("主题向量生成失败: $e", isError: true);
      return rawText; // 彻底失败则回退全量
    }

    onProgress?.call("正在计算余弦相似度并排序...", 0.95);
    List<MapEntry<String, double>> scoredChunks =[];
    for (int i = 0; i < chunks.length; i++) {
      final sim = _cosineSimilarity(queryVector, chunkEmbeddings[i]);
      scoredChunks.add(MapEntry(chunks[i], sim));
    }
    
    scoredChunks.sort((a, b) => b.value.compareTo(a.value));
    
    // 提取最相关的前 5 个片段
    int maxSelected = math.min(5, scoredChunks.length);
    List<String> selectedChunks = scoredChunks.take(maxSelected).map((e) => e.key).toList();

    onProgress?.call("上下文检索优化完成！", 1.0);
    return selectedChunks.join("\n\n");
  }
}

// ==========================================
// 5. 状态管理 - 出题控制与做题引擎 (进度管理追加)
// ==========================================
class ExamProvider extends ChangeNotifier {
  bool _isLoading = false;
  bool get isLoading => _isLoading;
  
  String _loadingStatus = "";
  String get loadingStatus => _loadingStatus;
  
  // 新增：具体的进度百分比值 (0.0 ~ 1.0)
  double _processProgress = 0.0;
  double get processProgress => _processProgress;
  
  String _errorMessage = "";
  String get errorMessage => _errorMessage;

  void _updateProgress(String status, double progress) {
    _loadingStatus = status;
    _processProgress = progress;
    notifyListeners();
  }

  Future<bool> processAndGenerate({
    required String rawText, required String topic, required int count, required String difficulty,
  }) async {
    _isLoading = true;
    _errorMessage = "";
    _updateProgress("引擎启动中...", 0.0);

    int? currentExamId; 

    try {
      if ((await ConfigService.getDeepSeekKey()).isEmpty) throw Exception("请先在设置中配置云端 API Key");

      _updateProgress("正在将原始知识库即时持久化...", 0.02);
      final provisionalExam = SavedExam(title: topic, examJson: "[]", knowledgeBase: rawText, createdAt: DateTime.now().millisecondsSinceEpoch);
      currentExamId = await DatabaseHelper.saveExam(provisionalExam);

      String processedText = rawText;
      final embeddingModel = await ConfigService.getEmbeddingModel();
      final lmUrl = await ConfigService.getLmStudioUrl();
      
      // 优化：不再使用字符长度卡死，只要有 embedding 模型且文本超过单块容量(600)即触发
      if (embeddingModel.isNotEmpty && rawText.length > 600) {
        processedText = await SemanticRetrievalService.getRelevantContext(
          rawText, topic, embeddingModel, lmUrl,
          onProgress: (status, progress) => _updateProgress(status, progress)
        );
      }

      final enableRerank = await ConfigService.getEnableRerank();
      if (enableRerank) {
        _updateProgress("正在执行 Rerank 精细重排序...", 1.0); // 进度条拉满进入模型推理状态
        processedText = await DualAIService._rerankContent(processedText);
      }
      
      _updateProgress("正在请求云端大模型构建结构化试卷...", 1.0); // 变为无尽等待状态
      final result = await DualAIService.generateMixedExam(
        contextText: processedText, topic: topic, count: count, difficulty: difficulty,
      );

      if (result.containsKey("error")) throw Exception(result["error"]);

      _updateProgress("正在持久化最终考题...", 1.0);
      final examJsonStr = jsonEncode(result['questions'] ??[]);

      final finalExam = SavedExam(id: currentExamId, title: topic, examJson: examJsonStr, knowledgeBase: rawText, createdAt: provisionalExam.createdAt);
      await DatabaseHelper.updateExam(finalExam);

      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = e.toString().replaceFirst("Exception: ", "");
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }
}

class ExamTakingProvider extends ChangeNotifier {
  SavedExam? _exam;
  List<ExamQuestion> _questions =[];
  
  int _currentIndex = 0;
  Map<int, dynamic> _userAnswers = {}; // 存储当前用户的作答
  Map<int, String> _aiFeedbacks = {}; // 存储 AI 诊断反馈

  bool _isEvaluating = false;
  bool _isSubmitted = false;

  int get currentIndex => _currentIndex;
  Map<int, dynamic> get userAnswers => _userAnswers;
  Map<int, String> get aiFeedbacks => _aiFeedbacks;
  List<ExamQuestion> get questions => _questions;
  bool get isEvaluating => _isEvaluating;
  bool get isSubmitted => _isSubmitted;
  double get progress => _questions.isEmpty ? 0 : (_userAnswers.length / _questions.length);

  void startExam(SavedExam exam) {
    _exam = exam;
    _questions = exam.parsedQuestions;
    _currentIndex = 0;
    _userAnswers = {};
    _aiFeedbacks = {};
    _isSubmitted = false;
    _isEvaluating = false;
    notifyListeners();
  }

  void setAnswer(dynamic answer) {
    _userAnswers[_currentIndex] = answer;
    notifyListeners();
  }

  void nextQuestion() {
    if (_currentIndex < _questions.length - 1) {
      _currentIndex++;
      notifyListeners();
    }
  }

  void prevQuestion() {
    if (_currentIndex > 0) {
      _currentIndex--;
      notifyListeners();
    }
  }

  Future<void> submitExam() async {
    _isEvaluating = true;
    _isSubmitted = true;
    notifyListeners();

    int score = 0;
    List<Future> evalTasks =[];
    
    for (int i = 0; i < _questions.length; i++) {
      var q = _questions[i];
      var ans = _userAnswers[i];
      bool isCorrectLocally = false;

      if (ans != null) {
        if (q.type == 'single_choice' || q.type == 'fill_blank') {
          isCorrectLocally = ans.toString().trim().toLowerCase() == q.correctAnswer.toString().trim().toLowerCase();
        } else if (q.type == 'multi_choice') {
          var correctList = List<String>.from(q.correctAnswer)..sort();
          var ansList = List<String>.from(ans)..sort();
          isCorrectLocally = correctList.join() == ansList.join();
        }
      }

      // 【核心控制】：只有当主观题，或者客观题做错时，才会调用云端大模型，极大降低 API 消耗
      if (isCorrectLocally && q.type != 'essay') {
        score += 1;
        _aiFeedbacks[i] = "完全正确！掌握得很扎实。"; // 命中缓存分支，无需请求 AI
      } else {
        evalTasks.add(DualAIService.evaluateUserAnswer(q, ans ?? "未作答").then((feedback) {
          _aiFeedbacks[i] = feedback;
        }));
      }
    }

    await Future.wait(evalTasks);
    // 持久化答题记录
    final record = ExamRecord(
      examId: _exam!.id!,
      score: score,
      userAnswersJson: jsonEncode(_userAnswers.map((key, value) => MapEntry(key.toString(), value?.toString() ?? "null"))),
      aiFeedbackJson: jsonEncode(_aiFeedbacks.map((key, value) => MapEntry(key.toString(), value?.toString() ?? "null"))),
      createdAt: DateTime.now().millisecondsSinceEpoch
    );
    await DatabaseHelper.saveExamRecord(record);

    _isEvaluating = false;
    notifyListeners();
  }
}

// ==========================================
// 6. 视图层 - 工作台与入口
// ==========================================
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<SavedExam> _history =[];

  @override
  void initState() { super.initState(); _loadHistory(); }
  
  Future<void> _loadHistory() async {
    final list = await DatabaseHelper.getAllExams();
    setState(() => _history = list);
  }

  void _startExam(SavedExam exam) {
    context.read<ExamTakingProvider>().startExam(exam);
    Navigator.push(context, MaterialPageRoute(builder: (_) => ExamTakingScreen(exam: exam)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("AI 互动助教"),
        actions:[
          IconButton(icon: const Icon(Icons.settings), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()))),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children:[
          Padding(padding: const EdgeInsets.all(16.0), child: Text("可用题库集", style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold))),
          Expanded(
            child: _history.isEmpty 
            ? const Center(child: Text("暂无数据，点击下方按钮导入资料出题", style: TextStyle(color: Colors.grey)))
            : ListView.builder(
                itemCount: _history.length,
                itemBuilder: (context, i) {
                  final item = _history[i];
                  return Card(
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.menu_book)),
                      title: Text(item.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text("题量: ${item.parsedQuestions.length} | 题型覆盖单选/多选/填空/简答"),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // [修改] 指向统一的 KnowledgeInputScreen
                          IconButton(
                            icon: const Icon(Icons.edit_document, color: Colors.teal),
                            tooltip: "编辑原始知识库",
                            onPressed: () {
                              if (item.knowledgeBase.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text("当前题库无原始知识库缓存，无法编辑。"))
                                );
                                return;
                              }
                              // 跳转到统一界面进行编辑
                              Navigator.push(
                                context,
                                MaterialPageRoute(builder: (_) => KnowledgeInputScreen(existingExam: item))
                              ).then((_) => _loadHistory());
                            }
                          ),
                          // 原有：重新从原知识库生成试卷
                          IconButton(
                            icon: const Icon(Icons.refresh, color: Colors.blue), 
                            tooltip: "从原知识库生成新考题", 
                            onPressed: () {
                              if (item.knowledgeBase.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("当前题库为旧版本生成，无原始知识库缓存。")));
                                return;
                              }
                              context.read<ExamProvider>().processAndGenerate(
                                rawText: item.knowledgeBase, topic: item.title, count: item.parsedQuestions.length, difficulty: "中等"
                              ).then((_) => _loadHistory());
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("正在后台洗牌生成新考题...")));
                            }
                          ),
                          // [新增] 本地知识库 Q&A 对话功能
                          IconButton(
                            icon: const Icon(Icons.question_answer, color: Colors.purple),
                            tooltip: "知识库问答与探讨",
                            onPressed: () {
                              if (item.knowledgeBase.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("当前题库无原始知识库，无法进行问答。")));
                                return;
                              }
                              Navigator.push(
                                context,
                                MaterialPageRoute(builder: (_) => ChatWithKnowledgeScreen(exam: item))
                              );
                            }
                          ),
                          IconButton(icon: const Icon(Icons.history), tooltip: "查看历史记录", onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ExamHistoryScreen(exam: item)))),
                          IconButton(icon: const Icon(Icons.delete, color: Colors.redAccent), onPressed: () async { await DatabaseHelper.deleteExam(item.id!); _loadHistory(); }),
                        ],
                      ),
                      onTap: () => _startExam(item),
                    ),
                  );
                },
              )
          )
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add), label: const Text("导入资料制卷"),
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const KnowledgeInputScreen())).then((_) => _loadHistory()),
      ),
    );
  }
}

// ==========================================
// 7. 视图层 - 互动考试组件
// ==========================================
class ExamTakingScreen extends StatefulWidget {
  final SavedExam exam;
  const ExamTakingScreen({super.key, required this.exam});

  @override
  State<ExamTakingScreen> createState() => _ExamTakingScreenState();
}

class _ExamTakingScreenState extends State<ExamTakingScreen> {
  final TextEditingController _textController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Consumer<ExamTakingProvider>(
      builder: (context, provider, child) {
        if (provider.isEvaluating) {
          return const Scaffold(body: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children:[
            CircularProgressIndicator(), SizedBox(height: 20), Text("AI 导师正在批改您的答卷并生成诊断报告...")
          ])));
        }

        if (provider.isSubmitted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const ExamResultScreen()));
          });
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        final q = provider.questions[provider.currentIndex];
        final currentAns = provider.userAnswers[provider.currentIndex];

        // 同步文本框内容
        if (q.type == 'fill_blank' || q.type == 'essay') {
          if (_textController.text != (currentAns ?? "")) _textController.text = (currentAns ?? "");
        }

        return Scaffold(
          appBar: AppBar(
            title: Text("正在答题：${widget.exam.title}"),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(4.0),
              child: LinearProgressIndicator(value: provider.progress, backgroundColor: Colors.grey.withOpacity(0.2)),
            ),
          ),
          body: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children:[
                Text("题目 ${provider.currentIndex + 1} / ${provider.questions.length}", style: const TextStyle(fontSize: 14, color: Colors.grey)),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children:[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer, borderRadius: BorderRadius.circular(4)),
                      child: Text(_getFormatTypeName(q.type), style: TextStyle(color: Theme.of(context).colorScheme.onPrimaryContainer, fontSize: 12)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: _renderMarkdown("### " + q.question, shrinkWrap: true)), // 使用 markdown H3 维持字号与加粗
                  ],
                ),
                const SizedBox(height: 24),
                
                // 动态渲染答题组件
                Expanded(
                  child: SingleChildScrollView(
                    child: _buildInputWidget(q, currentAns, provider),
                  ),
                ),

                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children:[
                    OutlinedButton(
                      onPressed: provider.currentIndex > 0 ? () => provider.prevQuestion() : null,
                      child: const Text("上一题"),
                    ),
                    provider.currentIndex < provider.questions.length - 1
                    ? FilledButton(
                        onPressed: () => provider.nextQuestion(),
                        child: const Text("下一题"),
                      )
                    : FilledButton.icon(
                        icon: const Icon(Icons.check),
                        label: const Text("提交评卷"),
                        style: FilledButton.styleFrom(backgroundColor: Colors.green),
                        onPressed: () => provider.submitExam(),
                      ),
                  ],
                )
              ],
            ),
          ),
        );
      },
    );
  }

  String _getFormatTypeName(String type) {
    switch (type) {
      case 'single_choice': return '单选题';
      case 'multi_choice': return '多选题';
      case 'fill_blank': return '填空题';
      case 'essay': return '应用/简答题';
      default: return '未知题型';
    }
  }

  Widget _buildInputWidget(ExamQuestion q, dynamic currentAns, ExamTakingProvider provider) {
    if (q.type == 'single_choice') {
      return Column(
        children: q.options.map((opt) => RadioListTile<String>(
          title: _renderMarkdown(opt, shrinkWrap: true), // 注入 Latex 渲染
          value: opt,
          groupValue: currentAns as String?,
          onChanged: (v) => provider.setAnswer(v),
        )).toList(),
      );
    } else if (q.type == 'multi_choice') {
      List<String> selections = currentAns != null ? List<String>.from(currentAns) :[];
      return Column(
        children: q.options.map((opt) => CheckboxListTile(
          title: _renderMarkdown(opt, shrinkWrap: true), // 注入 Latex 渲染
          value: selections.contains(opt),
          onChanged: (checked) {
            if (checked == true) selections.add(opt); else selections.remove(opt);
            provider.setAnswer(selections);
          },
        )).toList(),
      );
    } else {
      return TextField(
        controller: _textController,
        maxLines: q.type == 'essay' ? 8 : 1,
        decoration: InputDecoration(
          hintText: q.type == 'essay' ? "请输入您的思考与解答过程..." : "请输入填空答案",
          border: const OutlineInputBorder(),
        ),
        onChanged: (val) => provider.setAnswer(val),
      );
    }
  }
}

// ==========================================
// 8. 视图层 - 深度诊断报告与成绩单
// ==========================================
class ExamResultScreen extends StatelessWidget {
  const ExamResultScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.read<ExamTakingProvider>();
    final questions = provider.questions;

    return Scaffold(
      appBar: AppBar(title: const Text("AI 诊断与反馈")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children:[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(color: Colors.indigo.withOpacity(0.1), borderRadius: BorderRadius.circular(16)),
              child: Column(
                children:[
                  const Text("测验完成，AI 已完成诊断", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text("客观题得分（供参考）：${questions.where((q) => q.type != 'essay' && provider.aiFeedbacks[questions.indexOf(q)]!.contains('完全正确')).length} / ${questions.where((q) => q.type != 'essay').length}"),
                ],
              ),
            ),
            const SizedBox(height: 24),
            
            ...questions.asMap().entries.map((entry) {
              int idx = entry.key; ExamQuestion q = entry.value;
              String aiFeedback = provider.aiFeedbacks[idx] ?? "无反馈数据";
              dynamic userAns = provider.userAnswers[idx] ?? "未作答";
              bool isCorrect = aiFeedback.contains("完全正确");

              return Card(
                elevation: 2, margin: const EdgeInsets.only(bottom: 24),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children:[
                        // 题干渲染
                        _renderMarkdown("**Q${idx + 1}.** ${q.question}", shrinkWrap: true),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceVariant, borderRadius: BorderRadius.circular(8)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children:[
                              // 用户回答与标准答案渲染
                              const Text("📝 你的回答:", style: TextStyle(fontWeight: FontWeight.bold)),
                              const SizedBox(height: 4),
                              _renderMarkdown(userAns.toString(), shrinkWrap: true),
                              const SizedBox(height: 8),
                              const Text("🔑 标准答案:", style: TextStyle(fontWeight: FontWeight.bold)),
                              const SizedBox(height: 4),
                              _renderMarkdown(q.correctAnswer.toString(), shrinkWrap: true),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        // AI 评价模块渲染
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(color: Colors.amber.withOpacity(0.1), border: Border.all(color: Colors.amber.withOpacity(0.5)), borderRadius: BorderRadius.circular(12)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(children:[Icon(Icons.psychology, color: Colors.orange), SizedBox(width: 8), Text("AI 导师诊断:", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orange))]),
                              const Divider(),
                              _renderMarkdown(aiFeedback, shrinkWrap: true),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        // 解析模块渲染
                        ExpansionTile(
                          title: const Text("查看题目标准解析"),
                          children:[
                            Padding(
                              padding: const EdgeInsets.all(16.0), 
                              child: _renderMarkdown(q.analysis, shrinkWrap: true)
                            )
                          ],
                        )
                      ],
                  ),
                ),
              );
            }).toList(),
            
            FilledButton.icon(
              icon: const Icon(Icons.home), label: const Text("返回工作台"),
              onPressed: () => Navigator.popUntil(context, (route) => route.isFirst),
            )
          ],
        ),
      ),
    );
  }
}

// ==========================================
// 附加视图层 - 历史记录页与出题导入页...
// ==========================================

class ExamHistoryScreen extends StatefulWidget {
  final SavedExam exam;
  const ExamHistoryScreen({super.key, required this.exam});
  @override
  State<ExamHistoryScreen> createState() => _ExamHistoryScreenState();
}

class _ExamHistoryScreenState extends State<ExamHistoryScreen> {
  List<ExamRecord> _records =[];
  bool _isGeneratingGuidance = false;
  
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    var recs = await DatabaseHelper.getRecordsForExam(widget.exam.id!);
    setState(() => _records = recs);
  }

  void _generateGuidance() async {
    if (_records.isEmpty) return;
    setState(() => _isGeneratingGuidance = true);
    
    String guidance = await DualAIService.generatePersonalizedGuidance(
      widget.exam.title, _records, widget.exam.parsedQuestions
    );
    
    setState(() => _isGeneratingGuidance = false);
    if (!mounted) return;
    
    showDialog(context: context, builder: (_) => AlertDialog(
      title: const Text("🎓 AI 个性化指导"),
      content: SingleChildScrollView(child: Text(guidance, style: const TextStyle(height: 1.5))),
      actions:[TextButton(onPressed: () => Navigator.pop(context), child: const Text("我知道了"))],
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("${widget.exam.title} 答题历史")),
      body: _records.isEmpty 
        ? const Center(child: Text("尚未在此题库中进行过测验"))
        : Column(
            children:[
              Expanded(
                child: ListView.builder(
                  itemCount: _records.length,
                  itemBuilder: (ctx, i) {
                    final rec = _records[i];
                    return ListTile(
                      leading: const Icon(Icons.assessment, color: Colors.teal),
                      title: Text("测验时间: ${DateTime.fromMillisecondsSinceEpoch(rec.createdAt).toString().split('.')[0]}"),
                      subtitle: Text("客观题参考得分: ${rec.score}"),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: FilledButton.icon(
                    icon: _isGeneratingGuidance ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.psychology),
                    label: Text(_isGeneratingGuidance ? "正在分析错题记录..." : "基于历史错题生成学情指导"),
                    onPressed: _isGeneratingGuidance ? null : _generateGuidance,
                  ),
                ),
              )
            ],
          )
    );
  }
}

class KnowledgeInputScreen extends StatefulWidget {
  final SavedExam? existingExam; // [新增] 用于判定是否为编辑模式

  const KnowledgeInputScreen({super.key, this.existingExam});
  @override
  State<KnowledgeInputScreen> createState() => _KnowledgeInputScreenState();
}

class _KnowledgeInputScreenState extends State<KnowledgeInputScreen> {
  final TextEditingController _topicController = TextEditingController();
  final TextEditingController _textController = TextEditingController();
  int _questionCount = 5;

  bool _isProcessingFiles = false;
  int _totalFilesToProcess = 0;
  int _processedFilesCount = 0;
  bool _enableOCR = true;
  final String _ocrModel = "vision-model";
  bool _useNativePDF = true;

  final List<String> _logLines = ["[INFO] 系统已就绪，等待交互..."];
  final ScrollController _logScrollController = ScrollController();
  bool _isLogPanelExpanded = false;
  StreamSubscription? _logSubscription;

  bool get _isEditMode => widget.existingExam != null; // 判定标志

  @override
  void initState() {
    super.initState();
    // [新增] 如果为编辑模式，初始化填充数据
    if (_isEditMode) {
      _topicController.text = widget.existingExam!.title;
      _textController.text = widget.existingExam!.knowledgeBase;
      _questionCount = widget.existingExam!.parsedQuestions.length; // 同步当前题量
    }

    _logSubscription = AppLogger.stream.listen((log) {
      if (!mounted) return;
      setState(() {
        _logLines.add(log);
        if (_logLines.length > 300) _logLines.removeAt(0);
      });
      if (_isLogPanelExpanded) _scrollToBottom();
    });
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() => _isLogPanelExpanded = true);
        _scrollToBottom();
      }
    });
  }

  @override
  void dispose() {
    _logSubscription?.cancel();
    _logScrollController.dispose();
    _topicController.dispose();
    _textController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 50), () {
      if (_logScrollController.hasClients) {
        _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
      }
    });
  }

  // ==========================================
  // 文件批量处理与视觉识别流
  // ==========================================
  Future<void> _importFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom, 
      allowedExtensions:['txt', 'md', 'json', 'png', 'jpg', 'jpeg', 'pdf'],
      allowMultiple: true, 
    );
    
    if (result != null && result.files.isNotEmpty) {
      setState(() {
        _isProcessingFiles = true;
        _totalFilesToProcess = result.files.length;
        _processedFilesCount = 0;
        _isLogPanelExpanded = true; 
      });
      _scrollToBottom();
      
      AppLogger.log("📥 开始批量导入 $_totalFilesToProcess 个文件");
      AppLogger.log("📊 多模态模型配置: 启用=$_enableOCR, 模型=$_ocrModel, 原生PDF=$_useNativePDF");
      
      for (int i = 0; i < result.files.length; i++) {
        var file = result.files[i];
        String filePath = file.path!;
        String ext = path.extension(filePath).toLowerCase();

        String content = "";
        try {
          if (ext == '.png' || ext == '.jpg' || ext == '.jpeg') {
            if (_enableOCR) {
              AppLogger.log("🔍 对图片文件 ${file.name} 启用多模态模型识别");
              content = await DualAIService.performLocalOCR(filePath);
            } else {
              AppLogger.log("⚠️  多模态模型已禁用，跳过图片文件 ${file.name}");
              content = "[图片文件，多模态模型已禁用]";
            }
          } else if (ext == '.pdf') {
            if (_enableOCR) {
              AppLogger.log("🔍 对 PDF 文件 ${file.name} 启用多模态模型识别");
              if (_useNativePDF && (io.Platform.isLinux || io.Platform.isWindows || io.Platform.isMacOS)) {
                try { 
                  content = await _parsePdfWithOCR(filePath); 
                  AppLogger.log("✅ PDF 原生解析成功: ${file.name}");
                } catch (e) { 
                  AppLogger.log("⚠️  PDF 原生解析失败，回退到视觉模型: $e", isError: true);
                  content = await DualAIService.performLocalOCR(filePath); 
                }
              } else {
                content = await DualAIService.performLocalOCR(filePath);
              }
            } else {
              AppLogger.log("⚠️  多模态模型已禁用，跳过 PDF 文件 ${file.name}");
              content = "[PDF 文件，多模态模型已禁用]";
            }
          } else {
            content = await io.File(filePath).readAsString();
            AppLogger.log("📄 文本文件 ${file.name} 读取成功，长度: ${content.length} 字符");
          }
        } catch (e) {
          content = "\n[文件 ${file.name} 解析失败: $e]";
          AppLogger.log("❌ 文件 ${file.name} 解析失败: $e", isError: true);
        }

        setState(() {
          final prefix = _textController.text.isEmpty ? "" : "\n\n";
          _textController.text += "$prefix--- 📄 文件来源: ${file.name} ---\n$content";
          _processedFilesCount++;
        });
      }
      
      setState(() => _isProcessingFiles = false);
      AppLogger.log("✅ 队列全部解析完毕，准备就绪。");
    }
  }

  Future<String> _parsePdfWithOCR(String filePath) async {
    try {
      if (io.Platform.isLinux) {
        final check = await io.Process.run('which',['pdftoppm']);
        if (check.exitCode != 0) throw Exception("缺少 Linux 原生 PDF 依赖。终端执行: sudo apt-get install poppler-utils");

        final tempDir = await io.Directory.systemTemp.createTemp('ai_teacher_pdf_');
        await io.Process.run('pdftoppm',['-png', '-r', '150', filePath, '${tempDir.path}/page']);

        String accumulatedContent = "";
        final files = tempDir.listSync().whereType<io.File>().where((f) => f.path.endsWith('.png')).toList();
        files.sort((a, b) => a.path.compareTo(b.path));

        for (int i = 0; i < files.length; i++) {
          final pageText = await DualAIService.performLocalOCR(files[i].path);
          accumulatedContent += "\n[第${i+1}页提取]:\n$pageText\n";
          if (i < files.length - 1) await Future.delayed(const Duration(seconds: 2));
        }

        await tempDir.delete(recursive: true); 
        return accumulatedContent;
      } else {
        throw Exception("该系统需要原生 PDF 引擎。");
      }
    } catch (e) {
      return "[PDF 视觉提取失败]: $e";
    }
  }

  // [修改] 提交核心调度枢纽
  void _submitTask() async {
    if (_topicController.text.trim().isEmpty || _textController.text.trim().isEmpty) return;
    
    if (_isEditMode) {
      // ==== 编辑模式：执行原 KnowledgeEditScreen 的保存与 Rerank 逻辑 ====
      setState(() => _isProcessingFiles = true);
      String finalText = _textController.text.trim();
      
      final enableRerank = await ConfigService.getEnableRerank();
      if (enableRerank) {
        final rerankModel = await ConfigService.getRerankModel();
        if (rerankModel.isNotEmpty) {
          AppLogger.log("启动 Rerank 优化模型处理知识库文本...");
          try {
            final localUrl = await ConfigService.getLmStudioUrl();
            final response = await Dio().post(
              '$localUrl/chat/completions',
              options: Options(receiveTimeout: const Duration(minutes: 5)),
              data: {
                "model": rerankModel, 
                "messages":[
                  {"role": "system", "content": "你是一个文本重排序专家。请对输入的文本进行重新排序，将最重要的内容放在前面，按重要性递减的顺序排列。"},
                  {"role": "user", "content": "请对以下文本进行重排序：\n\n文本：$finalText"}
                ],
                "temperature": 0.1,
              },
            );
            final usage = response.data['usage'];
            AppLogger.log("Rerank 处理完毕，消耗 Tokens: [Prompt: ${usage?['prompt_tokens']}, Completion: ${usage?['completion_tokens']}]");
            finalText = response.data['choices'][0]['message']['content'];
          } catch (e) {
            AppLogger.log("Rerank 模型返回异常，使用原始文本保存", isError: true);
          }
        }
      }
      
      final updatedExam = SavedExam(
        id: widget.existingExam!.id,
        title: _topicController.text.trim(),
        examJson: widget.existingExam!.examJson,
        knowledgeBase: finalText,
        createdAt: widget.existingExam!.createdAt,
      );
      await DatabaseHelper.updateExam(updatedExam);
      
      if (mounted) {
        setState(() => _isProcessingFiles = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("✅ 知识库数据已成功更新")));
        Navigator.pop(context);
      }
    } else {
      // ==== 新建模式：执行出题引擎流程 ====
      final provider = context.read<ExamProvider>();
      final success = await provider.processAndGenerate(
        topic: _topicController.text.trim(), rawText: _textController.text.trim(), count: _questionCount, difficulty: "中等"
      );
      if (success && mounted) Navigator.pop(context);
    }
  }

  // ==========================================
  // UI：文件与日志控制台模块
  // ==========================================
  Widget _buildLogPanel() {
    double progress = _totalFilesToProcess > 0 ? (_processedFilesCount / _totalFilesToProcess) : 0.0;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children:[
          InkWell(
            onTap: () {
              setState(() => _isLogPanelExpanded = !_isLogPanelExpanded);
              if (_isLogPanelExpanded) _scrollToBottom();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children:[
                  Icon(_isLogPanelExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up),
                  const SizedBox(width: 8),
                  const Text("模型状态与数据库日志", style: TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  if (_isProcessingFiles) ...[
                    SizedBox(width: 100, child: LinearProgressIndicator(value: progress)),
                    const SizedBox(width: 12),
                    Text(
                      "文件处理中: $_processedFilesCount/$_totalFilesToProcess", 
                      style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.primary)
                    ),
                  ] else ...[
                    const Icon(Icons.circle, size: 10, color: Colors.green),
                    const SizedBox(width: 6),
                    const Text("引擎空闲", style: TextStyle(fontSize: 12, color: Colors.green)),
                  ]
                ],
              ),
            ),
          ),
          
          if (_isLogPanelExpanded)
            Container(
              height: 250,
              width: double.infinity,
              color: const Color(0xFF1E1E1E), 
              padding: const EdgeInsets.all(8),
              child: ListView.builder(
                controller: _logScrollController,
                itemCount: _logLines.length,
                itemBuilder: (context, index) {
                  final line = _logLines[index];
                  Color textColor = Colors.white70;
                  if (line.contains("[ERROR]")) {
                    textColor = Colors.redAccent;
                  } else if (line.contains("Tokens") || line.contains("消耗")) {
                    textColor = Colors.greenAccent;
                  } else if (line.contains("SQLite") || line.contains("数据库") || line.contains("💾")) {
                    textColor = Colors.amberAccent;
                  } else if (line.contains("🚀") || line.contains("📥") || line.contains("✅")) {
                    textColor = Colors.cyanAccent;
                  }

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4.0),
                    child: Text(line, style: TextStyle(color: textColor, fontFamily: 'monospace', fontSize: 12)),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ExamProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text("混合题型生成器")),
      body: provider.isLoading 
      ? Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 64.0), // 限制宽度使其优雅
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children:[
                // 当进度到达 1.0 时，表示进入大模型思考环节，转为循环动画；否则显示实际百分比进度
                provider.processProgress >= 1.0
                    ? const CircularProgressIndicator()
                    : LinearProgressIndicator(
                        value: provider.processProgress,
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(4),
                      ),
                const SizedBox(height: 24),
                Text(
                  provider.loadingStatus, 
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)
                ),
                const SizedBox(height: 8),
                if (provider.processProgress < 1.0 && provider.processProgress > 0)
                  Text(
                    "${(provider.processProgress * 100).toStringAsFixed(1)}%",
                    style: const TextStyle(color: Colors.grey, fontFamily: 'monospace'),
                  )
              ],
            ),
          ),
        )
      : Column(
          children:[
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, 
                  children:[
                    TextField(controller: _topicController, decoration: const InputDecoration(labelText: "出题方向", border: OutlineInputBorder())),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween, 
                      children:[
                        const Text("导入知识域", style: TextStyle(fontWeight: FontWeight.bold)),
                        TextButton.icon(
                          icon: const Icon(Icons.drive_folder_upload), 
                          label: const Text("批量导入文件"), 
                          onPressed: _isProcessingFiles ? null : _importFile
                        )
                      ]
                    ),
                    const SizedBox(height: 8),
                    
                    const SizedBox(height: 16),
                    TextField(
                      controller: _textController, 
                      maxLines: 15, 
                      decoration: InputDecoration(
                        hintText: _enableOCR 
                          ? "在此粘贴长文本，支持导入纯文本、图片或扫描件PDF。本地视觉模型将自动提取文字并剥离噪声..." 
                          : "在此粘贴长文本，支持导入纯文本。多模态模型功能已禁用，图片和PDF文件将不会被识别。",
                        border: const OutlineInputBorder()
                      )
                    ),
                    const SizedBox(height: 24),
                    
                    // [修改] 新建模式才显示题量下拉框，编辑模式隐藏
                    if (!_isEditMode) ...[
                      DropdownButtonFormField<int>(
                        value: _questionCount, 
                        decoration: const InputDecoration(labelText: "目标出题量", border: OutlineInputBorder()),
                        items:[3, 5, 10, 15].map((e) => DropdownMenuItem(value: e, child: Text("$e 题"))).toList(),
                        onChanged: (v) => setState(() => _questionCount = v!),
                      ),
                      const SizedBox(height: 32),
                    ],

                    SizedBox(
                      width: double.infinity, height: 50, 
                      // [修改] 动态变更按钮文案与图标
                      child: FilledButton.icon(
                        icon: Icon(_isEditMode ? Icons.save : Icons.auto_awesome), 
                        label: Text(_isEditMode ? "保存知识库更新" : "双流引擎开始制卷"), 
                        onPressed: _isProcessingFiles ? null : _submitTask
                      )
                    )
                  ]
                ),
              ),
            ),
            _buildLogPanel(),
          ],
        ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _dsKeyController = TextEditingController();
  final TextEditingController _lmUrlController = TextEditingController();
  final TextEditingController _chatModelController = TextEditingController();
  final TextEditingController _visionModelController = TextEditingController();
  final TextEditingController _rerankModelController = TextEditingController();
  final TextEditingController _embeddingModelController = TextEditingController();
  bool _enableRerank = false;

  @override void initState() { super.initState(); _loadConfig(); }
  
  Future<void> _loadConfig() async {
    _dsKeyController.text = await ConfigService.getDeepSeekKey();
    _lmUrlController.text = await ConfigService.getLmStudioUrl();
    _chatModelController.text = await ConfigService.getChatModel();
    _visionModelController.text = await ConfigService.getVisionModel();
    _rerankModelController.text = await ConfigService.getRerankModel();
    _embeddingModelController.text = await ConfigService.getEmbeddingModel();
    _enableRerank = await ConfigService.getEnableRerank();
    setState(() {});
  }
  
  Future<void> _saveConfig() async {
    await ConfigService.saveDeepSeekKey(_dsKeyController.text.trim());
    await ConfigService.saveLmStudioUrl(_lmUrlController.text.trim());
    await ConfigService.saveChatModel(_chatModelController.text.trim());
    await ConfigService.saveVisionModel(_visionModelController.text.trim());
    await ConfigService.saveRerankModel(_rerankModelController.text.trim());
    await ConfigService.saveEmbeddingModel(_embeddingModelController.text.trim());
    await ConfigService.setEnableRerank(_enableRerank);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("✅ 参数已持久化并生效")));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("引擎参数与模型映射配置")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24), 
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children:[
            const Text("云端验证大模型", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 12),
            TextField(controller: _dsKeyController, obscureText: true, decoration: const InputDecoration(labelText: "DeepSeek API Key", border: OutlineInputBorder())),
            
            const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Divider()),
            
            const Text("本地 LM-Studio 后端绑定", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            const Text("若返回 400 错误，请确保下方填写的模型标识符与 LM-Studio 中加载的完全一致（例如: qwen/qwen3.5-2b 或 qwen-vl-reranker-2b）。", style: TextStyle(color: Colors.redAccent, fontSize: 13)),
            const SizedBox(height: 16),
            
            TextField(controller: _lmUrlController, decoration: const InputDecoration(labelText: "LM-Studio 基础 URL", border: OutlineInputBorder())),
            const SizedBox(height: 16),
            TextField(controller: _chatModelController, decoration: const InputDecoration(labelText: "文本提炼模型标识 (Chat Model ID)", hintText: "qwen/qwen3.5-2b", border: OutlineInputBorder())),
            const SizedBox(height: 16),
            TextField(controller: _visionModelController, decoration: const InputDecoration(labelText: "视觉解析模型标识 (Vision Model ID)", hintText: "qwen-vl-chat", border: OutlineInputBorder())),
            const SizedBox(height: 16),
            TextField(controller: _rerankModelController, decoration: const InputDecoration(labelText: "重排序模型标识 (Rerank Model ID)", hintText: "qwen-vl-reranker-2b", border: OutlineInputBorder())),
            const SizedBox(height: 16),
            TextField(controller: _embeddingModelController, decoration: const InputDecoration(labelText: "嵌入模型标识 (Embedding Model ID)", hintText: "mxbai-embed-large", border: OutlineInputBorder())),
            
            const SizedBox(height: 16),
            // 添加rerank功能开关
            Row(
              children: [
                Switch(
                  value: _enableRerank,
                  onChanged: (value) {
                    setState(() {
                      _enableRerank = value;
                    });
                  },
                ),
                const Text("启用重排序功能", style: TextStyle(fontSize: 16)),
              ],
            ),
            
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity, height: 50,
              child: FilledButton(onPressed: _saveConfig, child: const Text("保存并应用")),
            ),
        ]),
      ),
    );
  }
}

// ==========================================
// 视图层 - 原始知识库编辑与 DAG 辅助理解组件
// ==========================================

class KnowledgeEditScreen extends StatefulWidget {
  final SavedExam exam;
  const KnowledgeEditScreen({super.key, required this.exam});

  @override
  State<KnowledgeEditScreen> createState() => _KnowledgeEditScreenState();
}

class _KnowledgeEditScreenState extends State<KnowledgeEditScreen> {
  late TextEditingController _textController;
  bool _isSaving = false;
  bool _isGeneratingDAG = false;
  
  // --- 状态机：文件处理进度 ---
  bool _isProcessingFiles = false;
  int _totalFilesToProcess = 0;
  int _processedFilesCount = 0;

  // --- 多模态模型选项配置 ---
  bool _enableOCR = true;
  final String _ocrModel = "vision-model";
  bool _useNativePDF = true;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.exam.knowledgeBase);
  }

  // --- [新增业务] 文件解析与多模态流集成 ---
  Future<void> _importFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom, 
      allowedExtensions:['txt', 'md', 'json', 'png', 'jpg', 'jpeg', 'pdf'],
      allowMultiple: true, 
    );
    
    if (result != null && result.files.isNotEmpty) {
      setState(() {
        _isProcessingFiles = true;
        _totalFilesToProcess = result.files.length;
        _processedFilesCount = 0;
      });
      
      AppLogger.log("📥 追加导入 $_totalFilesToProcess 个文件至知识库编辑区");
      
      for (int i = 0; i < result.files.length; i++) {
        var file = result.files[i];
        String filePath = file.path!;
        String ext = path.extension(filePath).toLowerCase();

        String content = "";
        try {
          if (ext == '.png' || ext == '.jpg' || ext == '.jpeg') {
            if (_enableOCR) {
              content = await DualAIService.performLocalOCR(filePath);
            } else {
              content = "[图片文件，多模态模型已禁用]";
            }
          } else if (ext == '.pdf') {
            if (_enableOCR) {
              if (_useNativePDF && io.Platform.isLinux) {
                try { 
                  content = await _parsePdfWithOCR(filePath); 
                } catch (e) { 
                  content = await DualAIService.performLocalOCR(filePath); 
                }
              } else {
                content = await DualAIService.performLocalOCR(filePath);
              }
            } else {
              content = "[PDF 文件，多模态模型已禁用]";
            }
          } else {
            content = await io.File(filePath).readAsString();
          }
        } catch (e) {
          content = "\n[文件 ${file.name} 解析失败: $e]";
        }

        setState(() {
          final prefix = _textController.text.isEmpty ? "" : "\n\n";
          _textController.text += "$prefix--- 📄 追加文件来源: ${file.name} ---\n$content";
          _processedFilesCount++;
        });
      }
      
      setState(() => _isProcessingFiles = false);
      AppLogger.log("✅ 追加队列全部解析完毕，已注入编辑器。");
    }
  }

  // --- [新增业务] Linux 依赖级 PDF 切割 ---
  Future<String> _parsePdfWithOCR(String filePath) async {
    try {
      final check = await io.Process.run('which',['pdftoppm']);
      if (check.exitCode != 0) throw Exception("缺少 Linux 原生 PDF 依赖...");

      final tempDir = await io.Directory.systemTemp.createTemp('ai_teacher_pdf_');
      await io.Process.run('pdftoppm',['-png', '-r', '150', filePath, '${tempDir.path}/page']);

      String accumulatedContent = "";
      final files = tempDir.listSync().whereType<io.File>().where((f) => f.path.endsWith('.png')).toList();
      files.sort((a, b) => a.path.compareTo(b.path));

      for (int i = 0; i < files.length; i++) {
        final pageText = await DualAIService.performLocalOCR(files[i].path);
        accumulatedContent += "\n[第${i+1}页提取]:\n$pageText\n";
        if (i < files.length - 1) await Future.delayed(const Duration(seconds: 2));
      }

      await tempDir.delete(recursive: true); 
      return accumulatedContent;
    } catch (e) {
      return "[PDF 视觉提取失败]: $e";
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  /// 业务逻辑：持久化保存修改后的文本（可选执行 Rerank 优化）
  Future<void> _saveChanges() async {
    setState(() => _isSaving = true);
    
    String finalText = _textController.text.trim();
    
    // 检查是否启用 Rerank 功能
    final enableRerank = await ConfigService.getEnableRerank();
    if (enableRerank) {
      final rerankModel = await ConfigService.getRerankModel();
      if (rerankModel.isNotEmpty) {
        // 显示 Rerank 进度条
        AppLogger.log("启动 Rerank 优化模型处理知识库文本...");
        try {
          final localUrl = await ConfigService.getLmStudioUrl();
          final response = await Dio().post(
            '$localUrl/chat/completions',
            options: Options(receiveTimeout: const Duration(minutes: 5)),
            data: {
              "model": rerankModel, 
              "messages":[
                {"role": "system", "content": "你是一个文本重排序专家。请对输入的文本进行重新排序，将最重要的内容放在前面，按重要性递减的顺序排列。"},
                {"role": "user", "content": "请对以下文本进行重排序：\n\n文本：$finalText"}
              ],
              "temperature": 0.1,
            },
          );
          final usage = response.data['usage'];
          AppLogger.log("Rerank 处理完毕，消耗 Tokens: [Prompt: ${usage?['prompt_tokens']}, Completion: ${usage?['completion_tokens']}]");
          finalText = response.data['choices'][0]['message']['content'];
        } catch (e) {
          AppLogger.log("Rerank 模型返回异常，使用原始文本保存", isError: true);
        }
      }
    }
    
    final updatedExam = SavedExam(
      id: widget.exam.id,
      title: widget.exam.title,
      examJson: widget.exam.examJson, // 保留原有考题 JSON
      knowledgeBase: finalText, // 更新原始参考文本（可能经过 Rerank 优化）
      createdAt: widget.exam.createdAt,
    );
    await DatabaseHelper.updateExam(updatedExam);
    setState(() => _isSaving = false);
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("✅ 原始数据已成功更新")));
      Navigator.pop(context);
    }
  }

  /// 业务逻辑：触发 DAG 生成并弹出结构化视图
  Future<void> _generateDAG() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    if (mounted) {
      setState(() => _isGeneratingDAG = true);
    }
    
    final dagCode = await DualAIService.generateKnowledgeDAG(text);
    
    if (mounted) {
      setState(() => _isGeneratingDAG = false);
      _showDAGDialog(dagCode);
    }
  }

  /// 渲染逻辑：展示生成的 DAG Mermaid 代码，并在 Linux 桌面端提供一键复制与提示
  void _showDAGDialog(String dagCode) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children:[
            const Icon(Icons.account_tree, color: Colors.blue),
            const SizedBox(width: 8),
            const Text("概念关联 DAG 图 (Mermaid)"),
          ],
        ),
        content: SizedBox(
          width: 600,
          height: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children:[
              const Text("已为您抽取出关键信息的逻辑化有向无环图，您可以复制下方代码并在任意支持 Mermaid 的渲染器中查看：", style: TextStyle(fontSize: 13, color: Colors.grey)),
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceVariant,
                    borderRadius: BorderRadius.circular(8)
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      dagCode,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions:[
          TextButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text("复制代码"),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: dagCode));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("DAG 代码已复制到剪贴板")));
            },
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("关闭"),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("编辑参考数据：${widget.exam.title}"),
        actions:[
          IconButton(
            icon: _isSaving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save),
            tooltip: "保存并覆盖",
            onPressed: _isSaving ? null : _saveChanges,
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children:[
            const SizedBox(height: 16),
            // [新增视图结构] 补充文件系统映射的触发器
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children:[
                const Text("原始参考文本内容", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                _isProcessingFiles 
                ? Row(
                    children:[
                      const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 8),
                      Text("处理中: $_processedFilesCount / $_totalFilesToProcess", style: TextStyle(color: Theme.of(context).colorScheme.primary))
                    ],
                  )
                : TextButton.icon(
                    icon: const Icon(Icons.drive_folder_upload),
                    label: const Text("选择文件追加导入"),
                    onPressed: _importFile,
                  )
              ],
            ),
            const SizedBox(height: 8),

            Expanded(
              child: TextField(
                controller: _textController,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: InputDecoration(
                  hintText: _enableOCR 
                    ? "在此编辑、修改或补充原始参考资料...支持导入纯文本、图片或扫描件PDF。本地视觉模型将自动提取文字并剥离噪声..." 
                    : "在此编辑、修改或补充原始参考资料...多模态模型功能已禁用，图片和PDF文件将不会被识别。",
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton.icon(
                icon: _isGeneratingDAG 
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) 
                  : const Icon(Icons.account_tree),
                label: Text(_isGeneratingDAG ? "正在执行逻辑流抽提..." : "AI 辅助理解：生成逻辑 DAG 图"),
                onPressed: _isGeneratingDAG ? null : _generateDAG,
              ),
            )
          ],
        ),
      ),
    );
  }
}
