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
// 附加视图层 - 知识库专属 Q&A 问答交互界面 (完整升级版)
// ==========================================
class ChatMessage {
  final String role; // 'user' or 'ai'
  final String text;
  final List<String>? sourceChunks; // [新增] 溯源内容
  ChatMessage({required this.role, required this.text, this.sourceChunks});
}

class ChatWithKnowledgeScreen extends StatefulWidget {
  final SavedExam exam;
  final String? initialMessage; //[新增] 用于接受上个界面的追问
  const ChatWithKnowledgeScreen({super.key, required this.exam, this.initialMessage});

  @override
  State<ChatWithKnowledgeScreen> createState() => _ChatWithKnowledgeScreenState();
}

class _ChatWithKnowledgeScreenState extends State<ChatWithKnowledgeScreen> {
  final List<ChatMessage> _messages = [];
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  
  late SavedExam _currentExam; // [新增] 维护当前库的最新状态
  bool _isReplying = false;
  bool _isGeneratingDAG = false;
  bool _isProcessingImage = false; // 控制图片解析状态
  bool _isGeneratingQuestion = false; // [新增] 出题状态
  
  // --- [文件1 新增] --- 
  // [修复-问题1] 增加状态变量：等待用户在对话框中作答的题目
  ExamQuestion? _pendingQuestionToAnswer;

  @override
  void initState() {
    super.initState();
    _currentExam = widget.exam;
    _messages.add(ChatMessage(
      role: 'ai', 
      text: "您好！我已经向量化学习了 **【${_currentExam.title}】**。您可以向我提问，或者在输入要求后点击右下角的【出题】按钮，我将为您单独生成一道题目并收录进题库！"
    ));

    // [新增] 如果带有初始追问信息，自动填充并发送
    if (widget.initialMessage != null) {
      _chatController.text = widget.initialMessage!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _sendMessage());
    }
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

  // --- [新增逻辑] 处理用户在对话框提交的文件/图片 ---
  Future<void> _handleFileAttachment() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom, 
      allowedExtensions: ['png', 'jpg', 'jpeg', 'pdf', 'txt'],
    );
    if (result != null && result.files.isNotEmpty) {
      setState(() => _isProcessingImage = true);
      String filePath = result.files.single.path!;
      String ext = path.extension(filePath).toLowerCase();
      String extractedText = "";

      try {
        if (['.png', '.jpg', '.jpeg', '.pdf'].contains(ext)) {
           extractedText = await DualAIService.performLocalOCR(filePath);
        } else {
           extractedText = await io.File(filePath).readAsString();
        }
        
        if (extractedText.trim().isNotEmpty) {
          // 将提取的内容直接填入输入框，让用户自由决定如何使用（提问或者要求收录）
          final prefix = _chatController.text.isEmpty ? "" : "${_chatController.text}\n";
          _chatController.text = "$prefix\n[附件分析提取内容]:\n$extractedText\n\n(请输入您的针对性问题...)";
        }
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("文件提取失败: $e")));
      } finally {
        setState(() => _isProcessingImage = false);
      }
    }
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

    // --- [文件1 修改点 1: 优先处理待作答题目] ---
    // [修复-问题1] 优先处理等待作答的测验题目逻辑，完成作答与智能评判
    if (_pendingQuestionToAnswer != null) {
      try {
        String feedback = await DualAIService.evaluateUserAnswerLocally(_pendingQuestionToAnswer!, text);
        if (mounted) {
          setState(() {
            _messages.add(ChatMessage(
              role: 'ai',
              text: "**💡 AI 导师批改结果：**\n\n$feedback\n\n**标准答案：**\n${_pendingQuestionToAnswer!.correctAnswer}\n\n**解析：**\n${_pendingQuestionToAnswer!.analysis}"
            ));
            _isReplying = false;
            _pendingQuestionToAnswer = null; // 清除状态
          });
          _scrollToBottom();
        }
      } catch (e) {
        AppLogger.log("批改异常: $e", isError: true);
        if (mounted) {
          setState(() {
            _messages.add(ChatMessage(role: 'ai', text: "批改过程出现异常: $e"));
            _isReplying = false;
            _pendingQuestionToAnswer = null;
          });
          _scrollToBottom();
        }
      }
      return; // 批改结束后直接返回，不进入普通问答
    }

    final embeddingModel = await ConfigService.getEmbeddingModel();
    
    List<String> retrievedChunks =[];
    String relevantContext = "";

    try {
      // 1. 强制依赖 Embedding 模型保障底层防溢出
      if (embeddingModel.isEmpty) {
        relevantContext = "[系统异常提示：未配置 Embedding 模型。为了避免触发 400 上下文溢出崩溃，系统已阻断此次全量文本请求。请前往设置页绑定大模型。]";
      } else if (_currentExam.id != null) {
        AppLogger.log("Q&A 触发本地 SQLite 向量库检索机制...");
        // 2. 从无限的 SQLite 库中提取 Top-5 的 Chunk 块
        retrievedChunks = await SemanticRetrievalService.searchContext(
          _currentExam.id!, text,
        );
        
        if (retrievedChunks.isNotEmpty) {
          // Top-5 的分块（每块约 600 字符）总计在 3000 字左右，天然保证绝对安全
          relevantContext = retrievedChunks.join("\n\n");
        } else {
          relevantContext = "[未能在向量数据库中命中高相关度内容，请依据模型基础认知尝试回答。]";
        }
      }

      // 3. 将经过精密组装的安全 Context 下发给大模型进行对话
      String aiResponse = await DualAIService.answerQuestionWithContext(text, relevantContext);

      // 4. 将提取出的来源碎片附带到 UI 进行渲染，方便溯源防幻觉
      if (mounted) {
        setState(() {
          _messages.add(ChatMessage(role: 'ai', text: aiResponse, sourceChunks: retrievedChunks));
          _isReplying = false;
        });
        _scrollToBottom();
      }
    } catch (e) {
      AppLogger.log("Q&A 交互处理链路异常: $e", isError: true);
      if (mounted) {
        setState(() {
          _messages.add(ChatMessage(role: 'ai', text: "请求由于内部异常中断：$e"));
          _isReplying = false;
        });
        _scrollToBottom();
      }
    }
  }

  // [新增] 利用对话框上下文动态生成题目并追加至数据库
  Future<void> _generateQuestionFromChat() async {
    final text = _chatController.text.trim();
    final intent = text.isEmpty ? "请随机抽取当前资料中的一个核心知识点，生成一道题目" : text;
    
    setState(() => _isGeneratingQuestion = true);
    _chatController.clear();

    final embeddingModel = await ConfigService.getEmbeddingModel();
    String relevantContext = "";
    
    // RAG 提取强相关资料
    if (embeddingModel.isNotEmpty && _currentExam.id != null) {
      final chunks = await SemanticRetrievalService.searchContext(_currentExam.id!, intent);
      if (chunks.isNotEmpty) relevantContext = chunks.join("\n\n");
    }

    final newQuestion = await DualAIService.generateSingleQuestionFromChat(relevantContext, intent);

    if (newQuestion != null) {
      // 追加到当前题库并更新 SQLite
      final questions = _currentExam.parsedQuestions;
      questions.add(newQuestion);
      
      _currentExam = SavedExam(
        id: _currentExam.id, title: _currentExam.title,
        examJson: jsonEncode(questions.map((q) => q.toJson()).toList()),
        knowledgeBase: _currentExam.knowledgeBase,
        createdAt: _currentExam.createdAt
      );
      await DatabaseHelper.updateExam(_currentExam);

      if (mounted) {
        setState(() {
          _messages.add(ChatMessage(role: 'ai', text: "✅ **已为您成功生成并收录了一道新考题：**\n\n**题型**：${newQuestion.type}\n**题目**：${newQuestion.question}\n**选项**：\n${newQuestion.options.map((e)=>'- $e').join('\n')}\n\n*（您可以在工作台直接启动测验以作答此题）*"));
        });
      }
    } else {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("题目生成失败，请稍后重试")));
    }
    
    setState(() => _isGeneratingQuestion = false);
    _scrollToBottom();
  }

  // --- DAG生成等逻辑保持之前的不变 ---
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
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _renderMarkdown(msg.text, isSelectable: true, shrinkWrap: true),
                              
                              // [新增溯源 UI] 如果包含参考切片数据，展示折叠面板
                              if (msg.sourceChunks != null && msg.sourceChunks!.isNotEmpty) ...[
                                const SizedBox(height: 12),
                                Theme(
                                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                                  child: ExpansionTile(
                                    tilePadding: EdgeInsets.zero,
                                    title: Text(
                                      "🔍 本次回答共参考 ${msg.sourceChunks!.length} 个本地向量条目",
                                      style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.primary),
                                    ),
                                    children: msg.sourceChunks!.map((chunk) => Container(
                                      margin: const EdgeInsets.only(bottom: 8),
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: Theme.of(context).colorScheme.surface,
                                        border: Border.all(color: Colors.grey.withOpacity(0.3)),
                                        borderRadius: BorderRadius.circular(6)
                                      ),
                                      child: SelectableText(
                                        chunk,
                                        style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
                                      ),
                                    )).toList(),
                                  ),
                                )
                              ]
                            ],
                          ),
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
            const Padding(padding: EdgeInsets.all(8.0), child: Text("AI 导师正在查阅资料并思考...", style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic))),
          
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children:[
                IconButton(
                  icon: _isProcessingImage ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.attach_file, color: Colors.blueGrey),
                  tooltip: "提取图片或文档内容",
                  onPressed: _isProcessingImage || _isReplying || _isGeneratingQuestion ? null : _handleFileAttachment,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _chatController, maxLines: 6, minLines: 1,
                    decoration: const InputDecoration(hintText: "提出疑问，或者输入出题指令后点击右侧的出题按钮...", border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 12),
                //[新增] 动态生成题目的快捷操作按钮
                Padding(
                  padding: const EdgeInsets.only(bottom: 4.0),
                  child: IconButton(
                    icon: _isGeneratingQuestion ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.add_task, color: Colors.indigo),
                    tooltip: "按左侧要求生成一道题目",
                    onPressed: _isReplying || _isGeneratingQuestion ? null : _generateQuestionFromChat,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4.0),
                  child: FilledButton(
                    onPressed: _isReplying || _isGeneratingQuestion ? null : _sendMessage,
                    style: FilledButton.styleFrom(shape: const CircleBorder(), padding: const EdgeInsets.all(16)),
                    child: const Icon(Icons.send),
                  ),
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
  String result = text
      .replaceAll(r'\[', r'$$')
      .replaceAll(r'\]', r'$$')
      .replaceAll(r'\(', r'$')
      .replaceAll(r'\)', r'$');
  // 如果文本中已经包含 $...$ 格式的 LaTeX，直接返回
  if (result.contains(r'$')) return result;
  // 检测纯文本中的数学表达式模式，自动包裹 $...$
  // 匹配 x^2, x^3, a^b, x_{1}, x_1, sqrt, frac 等常见数学表达式
  result = result.replaceAllMapped(
    RegExp(r'(?<!\$)([a-zA-Z]+\^[a-zA-Z0-9{}]+|[a-zA-Z]_\{[a-zA-Z0-9]+\}|[a-zA-Z]_\w+)(?!\$)'),
    (match) => '\$${match.group(0)}\$',
  );
  return result;
}

Widget _renderMarkdown(String content, {bool isSelectable = false, bool shrinkWrap = true}) {
  final processedContent = _preprocessLatex(content);
  return MarkdownBody(
    data: processedContent,
    selectable: isSelectable,
    shrinkWrap: shrinkWrap,
    styleSheet: MarkdownStyleSheet(
      p: const TextStyle(fontWeight: FontWeight.w400, fontSize: 16.0),
    ),
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

// ==========================================
// 1. 状态管理 - 全局主题与配置 (ConfigService 矩阵化重构)
// ==========================================
class ConfigService {
  static const _storage = FlutterSecureStorage();
  
  static Future<void> _migrateToMatrix() async {
    final migrated = await DatabaseHelper.getConfig("matrix_migrated_v6");
    if (migrated == "true") return;

    AppLogger.log("正在执行配置降维打击：将全局配置解耦为独立算子矩阵...");
    String globalPrimary = await DatabaseHelper.getConfig("primary_engine") ?? "cloud";
    String globalCloudUrl = await DatabaseHelper.getConfig("cloud_api_url") ?? "https://api.deepseek.com/v1";
    String globalCloudKey = await DatabaseHelper.getConfig("cloud_api_key") ?? await _storage.read(key: "deepseek_key") ?? "";
    String globalLocalUrl = await DatabaseHelper.getConfig("lm_studio_url") ?? "http://localhost:1234/v1";

    // 循环为四大引擎赋予独立配置副本
    for (String task in['chat', 'vision', 'rerank', 'embedding']) {
       await setConfigString('${task}_engine', globalPrimary);
       await setConfigString('${task}_cloud_url', globalCloudUrl);
       await setConfigString('${task}_cloud_key', globalCloudKey);
       await setConfigString('${task}_local_url', globalLocalUrl);
       await setConfigString('${task}_local_key', "lm-studio");
    }

    // 映射旧版模型名称
    await setConfigString('chat_cloud_model', await DatabaseHelper.getConfig("cloud_model_id") ?? "deepseek-chat");
    await setConfigString('chat_local_model', await DatabaseHelper.getConfig("lm_chat_model") ?? "");
    await setConfigString('vision_cloud_model', await DatabaseHelper.getConfig("cloud_vision_model") ?? "gpt-4o-mini");
    await setConfigString('vision_local_model', await DatabaseHelper.getConfig("lm_vision_model") ?? "");
    await setConfigString('rerank_cloud_model', await DatabaseHelper.getConfig("cloud_rerank_model") ?? "deepseek-chat");
    await setConfigString('rerank_local_model', await DatabaseHelper.getConfig("lm_rerank_model") ?? "");
    await setConfigString('embedding_cloud_model', await DatabaseHelper.getConfig("cloud_embedding_model") ?? "text-embedding-v1");
    await setConfigString('embedding_local_model', await DatabaseHelper.getConfig("lm_embedding_model") ?? "");

    await DatabaseHelper.saveConfig("matrix_migrated_v6", "true");
    AppLogger.log("矩阵配置升维完成！");
  }

  /// 泛型字符获取接口
  static Future<String> getConfigString(String key, String defaultValue) async {
    await _migrateToMatrix();
    return await DatabaseHelper.getConfig(key) ?? defaultValue;
  }

  /// 泛型字符写入接口
  static Future<void> setConfigString(String key, String value) async {
    await DatabaseHelper.saveConfig(key, value);
  }

  // 保持原有 Rerank 全局开关兼容性
  static Future<bool> getEnableRerank() async {
    await _migrateToMatrix();
    final value = await DatabaseHelper.getConfig("enable_rerank");
    return value?.toLowerCase() == "true";
  }
  static Future<void> setEnableRerank(bool enable) async {
    await DatabaseHelper.saveConfig("enable_rerank", enable.toString());
  }

  // ==========================================
  // 兼容层：为现有代码提供向后兼容的接口
  // ==========================================
  
  // 云端 API Key 兼容
  static Future<String> getCloudApiKey() async {
    // 从矩阵中获取 chat_cloud_key 作为默认云端密钥
    return await getConfigString('chat_cloud_key', '');
  }
  static Future<void> saveCloudApiKey(String key) async {
    // 保存到所有任务的云端密钥配置
    for (String task in['chat', 'vision', 'rerank', 'embedding']) {
      await setConfigString('${task}_cloud_key', key);
    }
  }

  // 云端 API URL 兼容
  static Future<String> getCloudApiUrl() async {
    return await getConfigString('chat_cloud_url', 'https://api.deepseek.com/v1');
  }
  static Future<void> saveCloudApiUrl(String url) async {
    for (String task in['chat', 'vision', 'rerank', 'embedding']) {
      await setConfigString('${task}_cloud_url', url);
    }
  }

  // 云端模型 ID 兼容
  static Future<String> getCloudModelId() async {
    return await getConfigString('chat_cloud_model', 'deepseek-chat');
  }
  static Future<void> saveCloudModelId(String model) async {
    await setConfigString('chat_cloud_model', model);
  }

  // 云端视觉模型 ID 兼容
  static Future<String> getCloudVisionModelId() async {
    return await getConfigString('vision_cloud_model', 'gpt-4o-mini');
  }
  static Future<void> saveCloudVisionModelId(String model) async {
    await setConfigString('vision_cloud_model', model);
  }

  // 云端 Rerank 模型 ID 兼容
  static Future<String> getCloudRerankModelId() async {
    return await getConfigString('rerank_cloud_model', 'deepseek-chat');
  }
  static Future<void> saveCloudRerankModelId(String model) async {
    await setConfigString('rerank_cloud_model', model);
  }

  // 云端 Embedding 模型 ID 兼容
  static Future<String> getCloudEmbeddingModelId() async {
    return await getConfigString('embedding_cloud_model', 'text-embedding-v1');
  }
  static Future<void> saveCloudEmbeddingModelId(String model) async {
    await setConfigString('embedding_cloud_model', model);
  }

  // 主引擎选择兼容
  static Future<String> getPrimaryEngine() async {
    return await getConfigString('chat_engine', 'cloud');
  }
  static Future<void> savePrimaryEngine(String engine) async {
    for (String task in['chat', 'vision', 'rerank', 'embedding']) {
      await setConfigString('${task}_engine', engine);
    }
  }

  // LM Studio URL 兼容
  static Future<String> getLmStudioUrl() async {
    return await getConfigString('chat_local_url', 'http://localhost:1234/v1');
  }
  static Future<void> saveLmStudioUrl(String url) async {
    for (String task in['chat', 'vision', 'rerank', 'embedding']) {
      await setConfigString('${task}_local_url', url);
    }
  }

  // 本地聊天模型兼容
  static Future<String> getChatModel() async {
    return await getConfigString('chat_local_model', 'local-model');
  }
  static Future<void> saveChatModel(String model) async {
    await setConfigString('chat_local_model', model);
  }

  // 本地视觉模型兼容
  static Future<String> getVisionModel() async {
    return await getConfigString('vision_local_model', 'vision-model');
  }
  static Future<void> saveVisionModel(String model) async {
    await setConfigString('vision_local_model', model);
  }

  // 本地 Rerank 模型兼容
  static Future<String> getRerankModel() async {
    return await getConfigString('rerank_local_model', '');
  }
  static Future<void> saveRerankModel(String model) async {
    await setConfigString('rerank_local_model', model);
  }

  // 本地 Embedding 模型兼容
  static Future<String> getEmbeddingModel() async {
    return await getConfigString('embedding_local_model', '');
  }
  static Future<void> saveEmbeddingModel(String model) async {
    await setConfigString('embedding_local_model', model);
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
  // 3. 数据层 - SQLite 数据库 (修改片段)
  // ==========================================
  class DatabaseHelper {
    static Database? _database;
    static Future<Database> get database async {
      if (_database != null) return _database!;
      _database = await _initDB();
      return _database!;
    }

  static Future<Database> _initDB() async {
    // 获取用户主目录：Windows 用 USERPROFILE，其他平台用 HOME
    final homeDir = io.Platform.environment['HOME'] 
        ?? io.Platform.environment['USERPROFILE'] 
        ?? '.';
    final docDir = io.Directory('$homeDir/.ai_teacher');
    if (!await docDir.exists()) await docDir.create(recursive: true);
    String dbPath = path.join(docDir.path, 'exams_v2.db'); 
    
    // [修改] 版本升级至 4，引入 app_config 表用于持久化模型配置
    return await openDatabase(dbPath, version: 4, onCreate: (db, version) async {
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
        // [新增] 本地向量索引表
        await db.execute('''
          CREATE TABLE exam_embeddings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            examId INTEGER NOT NULL,
            chunkText TEXT NOT NULL,
            vectorJson TEXT NOT NULL,
            FOREIGN KEY (examId) REFERENCES saved_exams (id) ON DELETE CASCADE
          )
        ''');
        // [新增] 应用配置表，用于存储模型配置等参数
        await db.execute('''
          CREATE TABLE app_config (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            config_key TEXT UNIQUE NOT NULL,
            config_value TEXT NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
      }, onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE saved_exams ADD COLUMN knowledgeBase TEXT DEFAULT ""');
        }
        if (oldVersion < 3) {
          await db.execute('''
            CREATE TABLE exam_embeddings (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              examId INTEGER NOT NULL,
              chunkText TEXT NOT NULL,
              vectorJson TEXT NOT NULL,
              FOREIGN KEY (examId) REFERENCES saved_exams (id) ON DELETE CASCADE
            )
          ''');
        }
        if (oldVersion < 4) {
          await db.execute('''
            CREATE TABLE app_config (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              config_key TEXT UNIQUE NOT NULL,
              config_value TEXT NOT NULL,
              updated_at INTEGER NOT NULL
            )
          ''');
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
    
    // [新增] 向量库持久化接口
    static Future<void> saveEmbeddings(int examId, List<Map<String, dynamic>> embeddings) async {
      final db = await database;
      await db.transaction((txn) async {
        // 每次保存前清空该题库的旧向量
        await txn.delete('exam_embeddings', where: 'examId = ?', whereArgs: [examId]);
        for (var e in embeddings) {
          await txn.insert('exam_embeddings', e);
        }
      });
    }

    // [新增] 获取某题库的所有向量数据
    static Future<List<Map<String, dynamic>>> getEmbeddingsForExam(int examId) async {
      final db = await database;
      return await db.query('exam_embeddings', where: 'examId = ?', whereArgs: [examId]);
    }

    // [新增] 应用配置管理方法
    static Future<void> saveConfig(String key, String value) async {
      final db = await database;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      await db.insert(
        'app_config',
        {
          'config_key': key,
          'config_value': value,
          'updated_at': timestamp,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    static Future<String?> getConfig(String key) async {
      final db = await database;
      final result = await db.query(
        'app_config',
        where: 'config_key = ?',
        whereArgs: [key],
        limit: 1,
      );
      if (result.isNotEmpty) {
        return result.first['config_value'] as String?;
      }
      return null;
    }

    static Future<Map<String, String>> getAllConfigs() async {
      final db = await database;
      final results = await db.query('app_config');
      final configs = <String, String>{};
      for (var row in results) {
        configs[row['config_key'] as String] = row['config_value'] as String;
      }
      return configs;
    }

    static Future<void> deleteConfig(String key) async {
      final db = await database;
      await db.delete('app_config', where: 'config_key = ?', whereArgs: [key]);
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

  /// [终极版] 全矩阵动态网关：所有任务各自独立路由
  static Future<Map<String, dynamic>> _buildEngineContext({String taskType = 'chat'}) async {
    // 1. 获取当前特定任务的引擎归属 (cloud 或 local)
    String engine = await ConfigService.getConfigString('${taskType}_engine', 'cloud'); 
    
    // 2. 根据归属拉取独立的 URL、Key 和 Model
    String url = await ConfigService.getConfigString('${taskType}_${engine}_url', engine == 'cloud' ? 'https://api.deepseek.com/v1' : 'http://localhost:1234/v1');
    String key = await ConfigService.getConfigString('${taskType}_${engine}_key', '');
    String model = await ConfigService.getConfigString('${taskType}_${engine}_model', '');

    if (url.isEmpty) throw Exception("⚠️ [$taskType] 业务流的 $engine 节点 URL 缺失，请前往设置面板配置");

    // 3. 智能拼接路由（自动适配 OpenAI 标准后端）
    String cleanBaseUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    String apiUrl = taskType == 'embedding' ? "$cleanBaseUrl/embeddings" : "$cleanBaseUrl/chat/completions";

    AppLogger.log("🔀 路由分配 | 业务流: [$taskType] -> 节点: $engine -> 模型: $model");

    return {
      "url": apiUrl,
      "key": key.isEmpty ? "default-token" : key,
      "model": model,
      "isLocal": engine == 'local'
    };
  }

  /// [修改] Rerank 接入动态网关
  static Future<String> _rerankContent(String context) async {
    final enableRerank = await ConfigService.getEnableRerank();
    if (!enableRerank) return context;
    
    final engineCtx = await _buildEngineContext(taskType: 'rerank');
    if ((engineCtx["model"] as String).isEmpty) return context;
    
    AppLogger.log("启动 Rerank 优化模型 [${engineCtx["model"]}]：正在剥离无关噪声...");
    try {
      final response = await _dio.post(
        engineCtx["url"],
        options: Options(
          headers: {"Authorization": "Bearer ${engineCtx["key"]}", "Content-Type": "application/json"},
          receiveTimeout: const Duration(minutes: 5)
        ),
        data: {
          "model": engineCtx["model"], 
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
      AppLogger.log("Rerank 模型返回异常，回退至原始内容: $e", isError: true);
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

  /// [核心方法修改] 混合出题引擎，对接动态网关
  static Future<Map<String, dynamic>> generateMixedExam({
    required String contextText, required String topic, required int count, required String difficulty, String customPrompt = "",
  }) async {
    final engineCtx = await _buildEngineContext();
    if (!engineCtx["isLocal"] && (engineCtx["key"] as String).isEmpty) {
      AppLogger.log("云端引擎缺失 API Key", isError: true);
      return {"error": "尚未配置云端 API Key，请前往设置面板配置或切换至本地模型"};
    }

    // 局部本地考点提炼保持不变
    await _draftIdeasLocally(contextText, count);

    AppLogger.log("向核心推理网关 [${engineCtx["model"]}] 请求最终 JSON 混合题型构建...");
    final prompt = """你是一个资深的学科出题专家。请基于以下提供的【知识库检索上下文】，针对主题【$topic】，生成一份高质量的混合题型试卷。
出题严格要求：
1. 题量：$count 道。难度：$difficulty。
2. 题型分布：必须包含单选、多选、填空、应用题（按照难度选择题型）。
3. 【用户自定义出题指令】：${customPrompt.isNotEmpty ? customPrompt : ''}
4. 需要具备一定的难度，贴近实际生活和考试要求，避免过于简单或过于学术化的题目。
5. 难度参考期末考试试卷难度。
【原始上下文】：\n$contextText
必须以严格 JSON 格式返回：{"questions":[{"type": "single_choice", "question": "题干", "options":["A", "B", "C", "D"], "correct_answer": "正确答案", "analysis": "详细解析"}]}""";

    try {
      final response = await _dio.post(
        engineCtx["url"],
        options: Options(
          headers: {"Authorization": "Bearer ${engineCtx["key"]}", "Content-Type": "application/json"},
          receiveTimeout: const Duration(minutes: 5),
        ),
        data: {
          "model": engineCtx["model"],
          "messages":[
            {"role": "system", "content": "你是一个严格的 JSON 出题机器。"},
            {"role": "user", "content": prompt}
          ],
          "temperature": 0.3,
        },
      );
      final usage = response.data['usage'];
      AppLogger.log("试卷构建成功！消耗 Tokens: [Prompt: ${usage?['prompt_tokens']}, Completion: ${usage?['completion_tokens']}]");
      
      String content = response.data['choices'][0]['message']['content'];
      return jsonDecode(_cleanJson(content));
    } catch (e) {
      AppLogger.log("出题请求网关异常: $e", isError: true);
      return {"error": "API 请求异常: $e"};
    }
  }

  /// [修改] 视觉模型 OCR 接入动态网关 (保留原方法名避免调用层报错)
  static Future<String> performLocalOCR(String filePath, {int maxRetries = 3}) async {
    final engineCtx = await _buildEngineContext(taskType: 'vision');
    if ((engineCtx["model"] as String).isEmpty) return "[未配置视觉模型]";

    AppLogger.log("触发视觉处理模型 [${engineCtx["model"]}]，正在解析: ${path.basename(filePath)}");

    final bytes = await io.File(filePath).readAsBytes();
    final base64Img = base64Encode(bytes);
    final mimeType = path.extension(filePath).toLowerCase() == '.png' ? 'image/png' : 'image/jpeg';

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final response = await _dio.post(
          engineCtx["url"],
          options: Options(
            headers: {"Authorization": "Bearer ${engineCtx["key"]}", "Content-Type": "application/json"},
            receiveTimeout: const Duration(minutes: 5), 
            validateStatus: (s) => s != null && s < 600
          ),
          data: {
            "model": engineCtx["model"], 
            "messages":[{"role": "user", "content":[{"type": "text", "text": "提取图片中的所有文本信息,但是也请描述图片内容,特别是示意图，如果遇到表格，请输出表格内容,请直接输出信息，不需要包含过多的格式。"},{"type": "image_url", "image_url": {"url": "data:$mimeType;base64,$base64Img"}}]}]
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
    final apiKey = await ConfigService.getCloudApiKey();
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

  // [新增] 优先使用本地 AI 进行阅卷批改，节省云端算力
  static Future<String> evaluateUserAnswerLocally(ExamQuestion q, dynamic userAnswer) async {
    final localUrl = await ConfigService.getLmStudioUrl();
    final chatModel = await ConfigService.getChatModel();
    
    // 如果没有配置本地模型，自动降级去请求云端
    if (chatModel.isEmpty) return await evaluateUserAnswer(q, userAnswer);

    AppLogger.log("启动本地 AI [$chatModel] 代劳进行阅卷批改...");
    final prompt = """
你是一个严谨的AI阅卷老师。请对学生的回答进行批改诊断。
题目：${q.question}
标准答案/采分点：${jsonEncode(q.correctAnswer)}
题目解析：${q.analysis}

考生回答：${jsonEncode(userAnswer)}

请判断考生的回答是否正确，并用50-100字简短指出其思维误区或闪光点。不要输出多余格式，直接回复文本评语。
""";

    try {
      final response = await _dio.post(
        '$localUrl/chat/completions',
        options: Options(receiveTimeout: const Duration(minutes: 2)),
        data: {
          "model": chatModel,
          "messages":[{"role": "user", "content": prompt}],
          "temperature": 0.2, // 低温度保证判卷严谨性
        },
      );
      return response.data['choices'][0]['message']['content'].toString().trim();
    } catch (e) {
      AppLogger.log("本地批改异常或超时，自动回退至云端大模型: $e", isError: true);
      return await evaluateUserAnswer(q, userAnswer); // Fallback
    }
  }

  /// 新增：基于持久化的历史记录，生成个性化指导
  static Future<String> generatePersonalizedGuidance(String examTitle, List<ExamRecord> records, List<ExamQuestion> questions) async {
    final apiKey = await ConfigService.getCloudApiKey();
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
    final apiKey = await ConfigService.getCloudApiKey();
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
    final apiKey = await ConfigService.getCloudApiKey();
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

  // [新增] 用于在对话框中根据用户指令动态生成单道题目
  static Future<ExamQuestion?> generateSingleQuestionFromChat(String contextText, String userIntent) async {
    final apiKey = await ConfigService.getCloudApiKey();
    if (apiKey.isEmpty) throw Exception("未配置云端 API Key");

    final prompt = """基于以下上下文，请满足用户的具体出题意图，生成【一道】高质量的测试题。
【用户出题意图】：$userIntent
【知识库上下文】：\n$contextText

必须严格以单个 JSON 对象格式返回（禁止返回数组列表）：
{"type": "single_choice 或 essay", "question": "题干", "options":["A", "B", "C", "D"], "correct_answer": "正确答案", "analysis": "详细解析"}""";

    try {
      final response = await _dio.post(
        "https://api.deepseek.com/v1/chat/completions",
        options: Options(headers: {"Authorization": "Bearer $apiKey", "Content-Type": "application/json"}),
        data: {"model": "deepseek-chat", "messages": [{"role": "user", "content": prompt}], "temperature": 0.4},
      );
      String content = _cleanJson(response.data['choices'][0]['message']['content']);
      return ExamQuestion.fromJson(jsonDecode(content));
    } catch (e) {
      AppLogger.log("对话框生成题目异常: $e", isError: true);
      return null;
    }
  }

  /// [新增] AI 辅助题库优化器 (为UI侧"AI 润色"功能提供后端服务)
  static Future<ExamQuestion?> optimizeQuestion(ExamQuestion draft, String optimizationIntent) async {
    final engineCtx = await _buildEngineContext();
    
    final prompt = """
你是一个资深的学科教研专家。请根据以下【优化诉求】，对下方给出的【题目草稿】进行润色和结构优化。
要求：
1. 修复语法、标点漏洞，提升严谨度。
2. 确保选项之间没有歧义。
3. 必须以单个严谨的 JSON 格式返回，包含优化后的结构：{"type": "${draft.type}", "question": "优化后的题干", "options":["A", "B", "C", "D"], "correct_answer": "正确答案", "analysis": "详细解析"}

【优化诉求】：${optimizationIntent.isEmpty ? "常规化教研润色，提升学术性" : optimizationIntent}
【题目草稿】：
${jsonEncode(draft.toJson())}
""";

    try {
      final response = await _dio.post(
        engineCtx["url"],
        options: Options(
          headers: {"Authorization": "Bearer ${engineCtx["key"]}", "Content-Type": "application/json"},
          receiveTimeout: const Duration(minutes: 2),
        ),
        data: {
          "model": engineCtx["model"],
          "messages": [{"role": "user", "content": prompt}],
          "temperature": 0.2,
        },
      );
      String content = _cleanJson(response.data['choices'][0]['message']['content']);
      return ExamQuestion.fromJson(jsonDecode(content));
    } catch (e) {
      AppLogger.log("题目优化异常: $e", isError: true);
      return null;
    }
  }
}

// ==========================================
// 4. 服务层 - 附加轻量级向量检索服务 (修改片段)
// ==========================================
class SemanticRetrievalService {
  static final Dio _dio = Dio();

  static List<String> _chunkText(String text, {int chunkSize = 600, int overlap = 100}) {
    if (text.length <= chunkSize) return [text];
    List<String> chunks = [];
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

  /// [核心修改] 统一由网关动态调拨，带上 Authorization 头规避 401 拦截
  static Future<void> buildAndSaveIndex(int examId, String rawText, {Function(String, double)? onProgress}) async {
    final engineCtx = await DualAIService._buildEngineContext(taskType: 'embedding');
    final String model = engineCtx["model"];
    final String url = engineCtx["url"];
    final String key = engineCtx["key"];

    if (model.isEmpty || rawText.isEmpty) return;
    
    onProgress?.call("正在进行文本语义分块...", 0.1);
    final chunks = _chunkText(rawText);
    List<Map<String, dynamic>> dbRecords = [];

    for (int i = 0; i < chunks.length; i++) {
      onProgress?.call("向量化提取: 第 ${i + 1}/${chunks.length} 块", 0.1 + 0.8 * (i / chunks.length));
      try {
        final response = await _dio.post(
          url,
          options: Options(
            headers: {"Authorization": "Bearer $key", "Content-Type": "application/json"},
            receiveTimeout: const Duration(seconds: 30)
          ),
          data: {"model": model, "input": chunks[i]},
        );
        final vector = List<double>.from(response.data['data'][0]['embedding']);
        dbRecords.add({
          'examId': examId,
          'chunkText': chunks[i],
          'vectorJson': jsonEncode(vector), 
        });
      } catch (e) {
        AppLogger.log("第 $i 块 Embedding 失败: $e", isError: true);
      }
    }
    
    onProgress?.call("正在写入本地 SQLite 向量库...", 0.95);
    await DatabaseHelper.saveEmbeddings(examId, dbRecords);
    AppLogger.log("✅ 题库 ID:$examId 的向量索引构建完成，共存入 ${dbRecords.length} 个切片。");
  }

  /// [核心修改] 调整检索引擎对接
  static Future<List<String>> searchContext(int examId, String query) async {
    final engineCtx = await DualAIService._buildEngineContext(taskType: 'embedding');
    final String model = engineCtx["model"];
    final String url = engineCtx["url"];
    final String key = engineCtx["key"];

    if (model.isEmpty) return [];

    List<Map<String, dynamic>> savedVectors = await DatabaseHelper.getEmbeddingsForExam(examId);
    if (savedVectors.isEmpty) return [];

    List<double> queryVector = [];
    try {
      final qRes = await _dio.post(
        url, 
        options: Options(headers: {"Authorization": "Bearer $key", "Content-Type": "application/json"}),
        data: {"model": model, "input": query}
      );
      queryVector = List<double>.from(qRes.data['data'][0]['embedding']);
    } catch (e) {
      AppLogger.log("主题向量生成失败: $e", isError: true);
      return [];
    }

    List<MapEntry<String, double>> scoredChunks = [];
    for (var record in savedVectors) {
      List<double> chunkVec = List<double>.from(jsonDecode(record['vectorJson']));
      double sim = _cosineSimilarity(queryVector, chunkVec);
      scoredChunks.add(MapEntry(record['chunkText'] as String, sim));
    }
    
    scoredChunks.sort((a, b) => b.value.compareTo(a.value));
    
    int maxSelected = math.min(10, scoredChunks.length);
    return scoredChunks.take(maxSelected).map((e) => e.key).toList();
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

  // [终极修复] 通过无限存储 + 动态精准切片组装，彻底规避 400 崩溃
  Future<bool> processAndGenerate({
    required String rawText, required String topic, required int count, required String difficulty, String customPrompt = "",
    bool useEmbedding = true,  // [新增] 是否使用向量化检索
  }) async {
    _isLoading = true;
    _errorMessage = "";
    _updateProgress("引擎启动中...", 0.0);

      try {
        if ((await ConfigService.getCloudApiKey()).isEmpty) throw Exception("请先在设置中配置云端 API Key");

        _updateProgress("正在将海量原始知识库全量持久化...", 0.02);
        final provisionalExam = SavedExam(title: topic, examJson: "[]", knowledgeBase: rawText, createdAt: DateTime.now().millisecondsSinceEpoch);
        int currentExamId = await DatabaseHelper.saveExam(provisionalExam);

        // 1. 根据 useEmbedding 参数决定是否执行向量化检索
        String processedText = rawText;
        if (useEmbedding) {
          final embeddingModel = await ConfigService.getEmbeddingModel();
          if (embeddingModel.isNotEmpty) {
            _updateProgress("正在进行文本碎片化与向量树重构...", 0.10);
            await SemanticRetrievalService.buildAndSaveIndex(currentExamId, rawText, onProgress: _updateProgress);

            // 2. 动态精准拼装上下文：利用主题词提取 Top-5 知识域切片
            _updateProgress("正在从向量库提取 '$topic' 的高维特征片段...", 0.90);
            final chunks = await SemanticRetrievalService.searchContext(currentExamId, topic);
            if (chunks.isNotEmpty) {
              processedText = chunks.join("\n\n");
            }
          } else {
            _updateProgress("未配置 Embedding 模型，跳过向量化，直接使用原始文本出题...", 0.50);
          }
        } else {
          _updateProgress("用户选择跳过向量化，直接使用原始文本出题...", 0.50);
        }

      // 3. 执行安全的本地 Rerank
      final enableRerank = await ConfigService.getEnableRerank();
      if (enableRerank) {
        _updateProgress("正在执行 Rerank 精细重排序...", 0.95); 
        processedText = await DualAIService._rerankContent(processedText);
      }
      
      // 4. 发送至出题引擎，此时上下文经过精准拼装，绝对安全
      _updateProgress("上下文组装完成，请求云端构建试卷...", 1.0); 
      final result = await DualAIService.generateMixedExam(
        contextText: processedText, topic: topic, count: count, difficulty: difficulty, customPrompt: customPrompt, // 传入自定义指令
      );

      if (result.containsKey("error")) throw Exception(result["error"]);

      _updateProgress("试卷构建完毕，正在持久化...", 1.0);
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
  // [新增] 暴露当前的 exam 实体给外部
  SavedExam? get exam => _exam;

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

      if (isCorrectLocally && q.type != 'essay') {
        score += 1;
        _aiFeedbacks[i] = "完全正确！掌握得很扎实。";
      } else {
        // [核心修改] 调用本地小模型进行阅卷，节省云端 API
        evalTasks.add(DualAIService.evaluateUserAnswerLocally(q, ans ?? "未作答").then((feedback) {
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
      aiFeedbackJson: jsonEncode(_aiFeedbacks.map((key, value) => MapEntry(key.toString(), value.toString()))),
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
        title: const Text("AI 互动助教 工作台"),
        actions: [
          // [新增] 显式的亮色/暗色主题切换
          Consumer<ThemeProvider>(
            builder: (context, themeProvider, child) {
              bool isDark = Theme.of(context).brightness == Brightness.dark;
              return IconButton(
                icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode, color: isDark ? Colors.amber : Colors.indigo),
                tooltip: "切换主题",
                onPressed: () => themeProvider.toggleTheme(!isDark),
              );
            },
          ),
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
                          // 重新从原知识库生成试卷（弹出配置对话框）
                          IconButton(
                            icon: const Icon(Icons.refresh, color: Colors.blue), 
                            tooltip: "从原知识库生成新考题", 
                            onPressed: () {
                              if (item.knowledgeBase.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("当前题库为旧版本生成，无原始知识库缓存。")));
                                return;
                              }
                              showDialog(
                                context: context,
                                builder: (ctx) => _RegenerateExamDialog(
                                  exam: item,
                                  onStart: (topic, count, difficulty, useEmbedding) async {
                                    Navigator.pop(ctx);
                                    final provider = context.read<ExamProvider>();
                                    await provider.processAndGenerate(
                                      rawText: item.knowledgeBase, topic: topic, count: count, difficulty: difficulty,
                                      useEmbedding: useEmbedding,
                                    );
                                    _loadHistory();
                                  },
                                ),
                              );
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
                          // [新增] 手动构建向量索引
                          IconButton(
                            icon: const Icon(Icons.storage, color: Colors.orange),
                            tooltip: "手动构建向量索引",
                            onPressed: () async {
                              if (item.knowledgeBase.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("当前题库无原始知识库，无法构建向量索引。")));
                                return;
                              }
                              final embeddingModel = await ConfigService.getEmbeddingModel();
                              if (embeddingModel.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("未配置 Embedding 模型，请先前往设置页配置。")));
                                return;
                              }
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("正在构建向量索引，请稍候...")));
                              await SemanticRetrievalService.buildAndSaveIndex(item.id!, item.knowledgeBase);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("✅ 向量索引构建完成")));
                              }
                            }
                          ),
                          // [新增] 题库管理功能
                          IconButton(
                            icon: const Icon(Icons.list_alt, color: Colors.teal),
                            tooltip: "管理题库题目",
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(builder: (_) => ExamQuestionManagerScreen(exam: item))
                              );
                            }
                          ),
                          // [新增] 查询提取底层向量片段
                          IconButton(
                            icon: const Icon(Icons.manage_search, color: Colors.deepPurple),
                            tooltip: "查询提取底层向量片段",
                            onPressed: () {
                              if (item.knowledgeBase.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("当前题库无原始知识库数据，无法查询。")));
                                return;
                              }
                              showDialog(context: context, builder: (_) => VectorSearchDialog(exam: item));
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

  void _handleGoNext(ExamTakingProvider provider) {
    if (provider.currentIndex < provider.questions.length - 1) {
      provider.nextQuestion();
    } else {
      provider.submitExam();
    }
  }

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

        // [修复] 空题库保护，防止 questions 为空时访问越界
        if (provider.questions.isEmpty) {
          return Scaffold(
            appBar: AppBar(title: Text("正在答题：${widget.exam.title}")),
            body: const Center(child: Text("当前题库为空，无法开始答题。")),
          );
        }

        final q = provider.questions[provider.currentIndex];
        final currentAns = provider.userAnswers[provider.currentIndex];

        // 同步文本框内容
        if (q.type == 'fill_blank' || q.type == 'essay') {
          if (_textController.text != (currentAns ?? "")) _textController.text = (currentAns ?? "");
        }

        // [修改核心] 使用 Focus 包裹 Scaffold，监听全局硬件回车键
        return Focus(
          autofocus: true,
          onKeyEvent: (FocusNode node, KeyEvent event) {
            // 拦截实体回车键（排除简答题，防止干扰正常打字换行）
            if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.enter) {
              if (q.type != 'essay') {
                _handleGoNext(provider);
                return KeyEventResult.handled;
              }
            }
            return KeyEventResult.ignored;
          },
          child: Scaffold(
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
                      Expanded(child: _renderMarkdown("### " + q.question, shrinkWrap: true)), 
                    ],
                  ),
                  const SizedBox(height: 24),
                  
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
                          child: const Text("下一题 (Enter)"), // [增加提示]
                        )
                      : FilledButton.icon(
                          icon: const Icon(Icons.check),
                          label: const Text("提交评卷 (Enter)"),
                          style: FilledButton.styleFrom(backgroundColor: Colors.green),
                          onPressed: () => provider.submitExam(),
                        ),
                    ],
                  )
                ],
              ),
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
    // 为 RadioListTile 和 CheckboxListTile 提供统一的 LaTeX 渲染选项组件
    Widget _buildLatexOption(String opt) {
      return _renderMarkdown(opt, shrinkWrap: true);
    }

    if (q.type == 'single_choice') {
      return Column(
        children: q.options.map((opt) => RadioListTile<String>(
          title: _buildLatexOption(opt),
          value: opt,
          groupValue: currentAns as String?,
          onChanged: (v) => provider.setAnswer(v),
        )).toList(),
      );
    } else if (q.type == 'multi_choice') {
      List<String> selections = currentAns != null ? List<String>.from(currentAns) :[];
      return Column(
        children: q.options.map((opt) => CheckboxListTile(
          title: _buildLatexOption(opt),
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
                        ),
                        // [新增] 针对本题进行追问的快捷入口
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            icon: const Icon(Icons.question_answer),
                            label: const Text("对此题有疑惑？向 AI 助教提问"),
                            onPressed: () {
                              final initialPrompt = "关于刚才测验中的一道题我不太理解。\n【题目】：${q.question}\n【我的回答是】：${userAns}\n【标准答案是】：${q.correctAnswer}\n请帮我详细分析一下我的思路哪里出了问题？";
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ChatWithKnowledgeScreen(
                                    exam: provider.exam!, 
                                    initialMessage: initialPrompt, // 传入自动生成的提问模板
                                  )
                                )
                              );
                            },
                          ),
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
// 附加视图层 - 题库管理界面 (替换原有 _ExamQuestionManagerScreenState)
// ==========================================
class ExamQuestionManagerScreen extends StatefulWidget {
  final SavedExam exam;
  const ExamQuestionManagerScreen({super.key, required this.exam});

  @override
  State<ExamQuestionManagerScreen> createState() => _ExamQuestionManagerScreenState();
}

class _ExamQuestionManagerScreenState extends State<ExamQuestionManagerScreen> {
  late List<ExamQuestion> _questions;
  
  @override
  void initState() {
    super.initState();
    _questions = List.from(widget.exam.parsedQuestions);
  }

  void _openEditorDialog({ExamQuestion? initialData, int? editIndex}) async {
    final result = await showDialog<ExamQuestion>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => QuestionEditorDialog(initialData: initialData),
    );

    if (result != null) {
      setState(() {
        if (editIndex != null) {
          _questions[editIndex] = result;
        } else {
          _questions.add(result);
        }
      });
      _saveChanges();
    }
  }

  void _deleteQuestion(int index) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("确认删除"),
        content: Text("确定要删除此题吗？操作无法撤销。"),
        actions:[
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          TextButton(
            onPressed: () {
              setState(() => _questions.removeAt(index));
              _saveChanges();
              Navigator.pop(ctx);
            },
            child: const Text("删除", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<void> _saveChanges() async {
    final updatedExam = SavedExam(
      id: widget.exam.id, title: widget.exam.title,
      examJson: jsonEncode(_questions.map((q) => q.toJson()).toList()),
      knowledgeBase: widget.exam.knowledgeBase, createdAt: widget.exam.createdAt,
    );
    await DatabaseHelper.updateExam(updatedExam);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("✅ 题库热更新成功")));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("题库教研室: ${widget.exam.title}"),
        actions:[
          IconButton(
            icon: const Icon(Icons.add_box), tooltip: "人工录入新题",
            onPressed: () => _openEditorDialog(),
          ),
          const SizedBox(width: 8)
        ],
      ),
      body: _questions.isEmpty
          ? const Center(child: Text("题库已空闲，请通过右上角或重新扫描文档新增题录。"))
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _questions.length,
              itemBuilder: (context, index) {
                final question = _questions[index];
                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    leading: CircleAvatar(child: Text("${index + 1}")),
                    title: Text(
                      question.question.replaceAll('\n', ' '),
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text("题型: ${question.type} | 答案: ${question.correctAnswer}"),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children:[
                        IconButton(icon: const Icon(Icons.edit, color: Colors.blue), onPressed: () => _openEditorDialog(initialData: question, editIndex: index)),
                        IconButton(icon: const Icon(Icons.delete, color: Colors.redAccent), onPressed: () => _deleteQuestion(index)),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

// [新增组件] 功能完整的富文本态试题表单引擎
class QuestionEditorDialog extends StatefulWidget {
  final ExamQuestion? initialData;
  const QuestionEditorDialog({super.key, this.initialData});

  @override
  State<QuestionEditorDialog> createState() => _QuestionEditorDialogState();
}

class _QuestionEditorDialogState extends State<QuestionEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  
  late String _type;
  late List<String> _allowedTypes; // [新增] 动态题型列表
  late TextEditingController _questionCtrl;
  late TextEditingController _correctAnswerCtrl;
  late TextEditingController _analysisCtrl;
  late List<TextEditingController> _optionsCtrls;
  
  bool _isOptimizing = false;

  @override
  void initState() {
    super.initState();
    // [修改点] 引入动态校验
    _allowedTypes =['single_choice', 'multi_choice', 'fill_blank', 'essay'];
    _type = widget.initialData?.type ?? 'single_choice';
    if (!_allowedTypes.contains(_type)) {
      _allowedTypes.add(_type); // 如果大模型犯蠢生成了未知题型，将其加入列表允许展示
    }
    
    _questionCtrl = TextEditingController(text: widget.initialData?.question ?? '');
    _analysisCtrl = TextEditingController(text: widget.initialData?.analysis ?? '');
    
    // 兼容答案类型的格式化
    dynamic ans = widget.initialData?.correctAnswer;
    if (ans is List) {
      _correctAnswerCtrl = TextEditingController(text: ans.join(','));
    } else {
      _correctAnswerCtrl = TextEditingController(text: ans?.toString() ?? '');
    }

    _optionsCtrls = (widget.initialData?.options ?? ['']).map((e) => TextEditingController(text: e)).toList();
    if (_optionsCtrls.isEmpty) _optionsCtrls.add(TextEditingController());
  }

  @override
  void dispose() {
    _questionCtrl.dispose(); _correctAnswerCtrl.dispose(); _analysisCtrl.dispose();
    for (var c in _optionsCtrls) { c.dispose(); }
    super.dispose();
  }

  void _applyAIModelRefinement() async {
    if (!_formKey.currentState!.validate()) return;
    
    setState(() => _isOptimizing = true);
    
    final currentDraft = ExamQuestion(
      type: _type,
      question: _questionCtrl.text,
      options: _optionsCtrls.map((e) => e.text).where((e) => e.isNotEmpty).toList(),
      correctAnswer: _correctAnswerCtrl.text,
      analysis: _analysisCtrl.text
    );

    final optimized = await DualAIService.optimizeQuestion(currentDraft, "请提升这道题的学术规范性和严谨性");
    
    setState(() => _isOptimizing = false);

    if (optimized != null) {
      setState(() {
        _questionCtrl.text = optimized.question;
        _analysisCtrl.text = optimized.analysis;
        // 动态覆盖选项组
        _optionsCtrls.clear();
        for (var opt in optimized.options) { _optionsCtrls.add(TextEditingController(text: opt)); }
        // 适配答案
        if (optimized.correctAnswer is List) {
          _correctAnswerCtrl.text = optimized.correctAnswer.join(',');
        } else {
          _correctAnswerCtrl.text = optimized.correctAnswer.toString();
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("✅ AI 教研模型润色完成")));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("❌ 润色失败，请检查模型网关连通性")));
    }
  }

  void _save() {
    if (_formKey.currentState!.validate()) {
      dynamic finalAns = _correctAnswerCtrl.text.trim();
      if (_type == 'multi_choice') {
        finalAns = finalAns.toString().split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      }
      final result = ExamQuestion(
        type: _type,
        question: _questionCtrl.text.trim(),
        options: _optionsCtrls.map((c) => c.text.trim()).where((e) => e.isNotEmpty).toList(),
        correctAnswer: finalAns,
        analysis: _analysisCtrl.text.trim(),
      );
      Navigator.pop(context, result);
    }
  }

  @override
  Widget build(BuildContext context) {
    bool hasOptions =['single_choice', 'multi_choice'].contains(_type);

    return AlertDialog(
      title: Row(
        children:[
          const Text("题目设计控制台"),
          const Spacer(),
          // 一键大模型联动按钮
          FilledButton.tonalIcon(
            icon: _isOptimizing ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.auto_awesome),
            label: const Text("AI 教研润色"),
            onPressed: _isOptimizing ? null : _applyAIModelRefinement,
          )
        ],
      ),
      content: SizedBox(
        width: 800, 
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children:[
                DropdownButtonFormField<String>(
                  value: _type,
                  decoration: const InputDecoration(labelText: "业务流题型", border: OutlineInputBorder()),
                  items: _allowedTypes.map((t) {
                    String label;
                    switch (t) {
                      case 'single_choice': label = "单选题"; break;
                      case 'multi_choice': label = "多选题"; break;
                      case 'fill_blank': label = "填空题"; break;
                      case 'essay': label = "简答论述题"; break;
                      default: label = "⚠️ 未知题型异常 ($t) - 请修改此项"; break;
                    }
                    return DropdownMenuItem(value: t, child: Text(label));
                  }).toList(),
                  onChanged: (v) => setState(() => _type = v!),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _questionCtrl, maxLines: 4, minLines: 2,
                  decoration: const InputDecoration(labelText: "题干详情 (支持 Markdown & LaTeX)", border: OutlineInputBorder()),
                  validator: (v) => v!.isEmpty ? '题干不可为空' : null,
                ),
                const SizedBox(height: 16),
                
                if (hasOptions) ...[
                  const Text("分支选项 (选项流):", style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  ..._optionsCtrls.asMap().entries.map((entry) {
                    int idx = entry.key;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: Row(
                        children:[
                          Expanded(
                            child: TextFormField(
                              controller: _optionsCtrls[idx],
                              decoration: InputDecoration(labelText: "选项标识 (例如 A. 内容)", border: const OutlineInputBorder(), isDense: true),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                            onPressed: () => setState(() {
                              if (_optionsCtrls.length > 1) {
                                _optionsCtrls[idx].dispose();
                                _optionsCtrls.removeAt(idx);
                              }
                            }),
                          )
                        ],
                      ),
                    );
                  }).toList(),
                  TextButton.icon(
                    icon: const Icon(Icons.add), label: const Text("追加扰乱项"),
                    onPressed: () => setState(() => _optionsCtrls.add(TextEditingController())),
                  ),
                  const SizedBox(height: 16),
                ],

                TextFormField(
                  controller: _correctAnswerCtrl,
                  decoration: InputDecoration(
                    labelText: _type == 'multi_choice' ? "标定锚点（多个请用英文逗号隔开）" : "标准采分点", 
                    border: const OutlineInputBorder()
                  ),
                  validator: (v) => v!.isEmpty ? '答案标准链不可缺失' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _analysisCtrl, maxLines: 5, minLines: 2,
                  decoration: const InputDecoration(labelText: "教研解析", border: OutlineInputBorder()),
                ),
              ],
            ),
          ),
        ),
      ),
      actions:[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("终止放弃")),
        FilledButton.icon(
          icon: const Icon(Icons.check), label: const Text("编译存档"),
          onPressed: _isOptimizing ? null : _save,
        ),
      ],
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
  final TextEditingController _customPromptController = TextEditingController(); // [新增] 自定义出题指令框
  int _questionCount = 5;

  // --- [修改目标] 全量内存缓冲区，替代 TextField 作为主存储 ---
  final StringBuffer _knowledgeTextBuffer = StringBuffer(); // 全量文本缓冲区
  String _previewSummary = ''; // 用于在 TextField 中展示简短摘要
  final int _maxPreviewChars = 5000; // TextField 最多显示字符数
  int _totalParsedChars = 0; // 已解析总字符数

  // --- 升级的状态机：异步任务队列与游标 ---
  bool _isProcessingQueue = false;
  final List<String> _pendingPaths = []; // 文件路径队列
  String? _activeFile; // 当前正在处理的文件
  int _activePage = 0; // 当前处理到的页码（用于PDF分页）
  int _totalFilesToProcess = 0;
  int _processedFilesCount = 0;

  // --- [文件1 新增] 状态变量 ---
  // [修复-问题4] 添加专用于数据库向量化持久化的状态，减轻焦虑
  bool _isSavingDB = false;
  String _saveStatus = "";
  double _saveProgress = 0.0;

  bool _enableOCR = true;
  bool _useNativePDF = true;

  final List<String> _logLines = ["[INFO] 系统已就绪，等待交互..."];
  final ScrollController _logScrollController = ScrollController();
  StreamSubscription? _logSubscription;
  bool _isLogPanelExpanded = false;

  bool get _isEditMode => widget.existingExam != null;

  @override
  void initState() {
    super.initState();
    // [修改目标] 如果为编辑模式，将已有 knowledgeBase 放入缓冲区
    if (_isEditMode) {
      _topicController.text = widget.existingExam!.title;
      _knowledgeTextBuffer.write(widget.existingExam!.knowledgeBase);
      _totalParsedChars = _knowledgeTextBuffer.length;
      _updatePreview(); // 更新预览摘要
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

  // [修改目标] 刷新预览文本
  void _updatePreview() {
    String fullText = _knowledgeTextBuffer.toString();
    if (fullText.length <= _maxPreviewChars) {
      _previewSummary = fullText;
    } else {
      _previewSummary = fullText.substring(0, _maxPreviewChars) +
          "\n\n... (已省略 ${fullText.length - _maxPreviewChars} 个字符，全部内容已安全存储于后台)";
    }
    _textController.text = _previewSummary;
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 50), () {
      if (_logScrollController.hasClients) {
        _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
      }
    });
  }

  // ==========================================
  // [新增] 特性 1 & 4: 底层文本解码与 Word 文档解析 (Debian 13 原生优化)
  // ==========================================
  Future<String> _readTextFileSmart(String filePath) async {
    try {
      // 尝试标准 UTF-8 解码
      return await io.File(filePath).readAsString();
    } catch (e) {
      AppLogger.log("⚠️ 检测到非标准 UTF-8 编码，触发底层 iconv 转换探测: ${path.basename(filePath)}");
      try {
        final encRes = await io.Process.run('file', ['-b', '--mime-encoding', filePath]);
        String charset = encRes.stdout.toString().trim();
        
        if (charset.isNotEmpty && charset != 'binary') {
          final iconvRes = await io.Process.run('iconv', ['-f', charset, '-t', 'utf-8', filePath]);
          if (iconvRes.exitCode == 0) {
            AppLogger.log("✅ 成功将 $charset 转换为 UTF-8");
            return iconvRes.stdout.toString();
          }
        }
        return "\n[文件解码失败: 不受支持的底层编码 ($charset) 或乱码]";
      } catch (osError) {
        return "\n[操作系统级解码异常: $osError]";
      }
    }
  }

  // [修改] 特性 1 & 4: 底层文本解码与 Word 文档解析 (KnowledgeInputScreen 中)
  Future<String> _parseWordDocument(String filePath, String ext) async {
    try {
      // [核心修复] 对抗 Linux 终端环境下的路径空格和特殊符号截断
      final escapedPath = filePath.replaceAll("'", "'\\''");

      if (ext == '.docx') {
        final res = await io.Process.run('sh',['-c', "unzip -p '$escapedPath' word/document.xml | sed -e 's/<[^>]*>//g'"]);
        if (res.exitCode == 0) return res.stdout.toString();
        throw Exception(res.stderr.toString());
      } else if (ext == '.doc') {
        // 策略1：使用轻量级 catdoc (成功率高且对中文友好)
        var res = await io.Process.run('catdoc', [filePath]);
        if (res.exitCode == 0 && res.stdout.toString().trim().isNotEmpty) return res.stdout.toString();
        
        // 策略2：使用 antiword
        res = await io.Process.run('antiword', [filePath]);
        if (res.exitCode == 0 && res.stdout.toString().trim().isNotEmpty) return res.stdout.toString();

        // 策略3：降级使用 libreoffice 隐式转换引擎
        final tempDir = await io.Directory.systemTemp.createTemp('doc_convert_');
        res = await io.Process.run('libreoffice',['--headless', '--convert-to', 'txt:Text', '--outdir', tempDir.path, filePath]);
        if (res.exitCode == 0) {
            final outName = "${path.basenameWithoutExtension(filePath)}.txt";
            final outFile = io.File(path.join(tempDir.path, outName));
            if (await outFile.exists()) {
                final content = await outFile.readAsString();
                await tempDir.delete(recursive: true);
                return content;
            }
        }
        throw Exception("Debian 系统需要依赖处理过时的 doc，请在终端执行: sudo apt install catdoc");
      }
      return "";
    } catch (e) {
      AppLogger.log("❌ Word 文件解析异常 ($ext): $e", isError: true);
      return "\n[Word 解析失败: $e (建议在原环境将其另存为 PDF/TXT后再试)]";
    }
  }

  // ==========================================
  // [修改] 具备系统休眠冻结保护的异步流水线
  // ==========================================
  Future<void> _processFileQueue() async {
    if (_isProcessingQueue) return;
    setState(() => _isProcessingQueue = true);

    while (_pendingPaths.isNotEmpty || _activeFile != null) {
      if (_activeFile == null) {
        _activeFile = _pendingPaths.removeAt(0);
        _activePage = 0;
        // 切换新文件时存档（这里简化处理，实际项目中可能需要调用 _syncStateToDB）
      }

      String filePath = _activeFile!;
      String ext = path.extension(filePath).toLowerCase();

      AppLogger.log("⚙️ 正在解析 (${_processedFilesCount + 1}/$_totalFilesToProcess): ${path.basename(filePath)} [断点: 第 $_activePage 页]");

      try {
        if (ext == '.pdf') {
           if (_enableOCR && _useNativePDF && io.Platform.isLinux) {
              await _parsePdfWithOCR(filePath, _activePage, (page, total, text) async {
                 if (mounted) {
                    setState(() {
                       _knowledgeTextBuffer.write(text);
                       _totalParsedChars = _knowledgeTextBuffer.length;
                       _updatePreview();
                       _activePage = page + 1;
                    });
                 }
              });
           } else {
              if (_activePage == 0) {
                  String content = _enableOCR ? await DualAIService.performLocalOCR(filePath) : "[PDF 模型禁用]";
                  if (mounted) setState(() {
                    _knowledgeTextBuffer.write("\n$content");
                    _totalParsedChars = _knowledgeTextBuffer.length;
                    _updatePreview();
                  });
                  _activePage = 1; 
              }
           }
        } else {
           if (_activePage == 0) {
               String content = "";
               if (['.png', '.jpg', '.jpeg'].contains(ext)) {
                  content = _enableOCR ? await DualAIService.performLocalOCR(filePath) : "[图片模型禁用]";
               } else if (ext == '.doc' || ext == '.docx') {
                  content = await _parseWordDocument(filePath, ext);
               } else {
                  content = await _readTextFileSmart(filePath);
               }
               
               if (mounted) {
                  setState(() {
                     final prefix = _knowledgeTextBuffer.isEmpty ? "" : "\n\n";
                     _knowledgeTextBuffer.write("$prefix--- 📄 来源: ${path.basename(filePath)} ---\n$content");
                     _totalParsedChars = _knowledgeTextBuffer.length;
                     _updatePreview();
                  });
               }
               _activePage = 1;
           }
        }

        // --- 若能运行到这里，说明整个文件顺利结束，开始推进下一个文件 ---
        _activeFile = null;
        _activePage = 0;
        _processedFilesCount++;
        // 存档（简化处理）

      } catch (e) {
        String errStr = e.toString().toLowerCase();
        
        // [核心修复] 如果判定为大模型后端超时、系统休眠或连接重置，触发【挂起保护】！
        if (errStr.contains("timeout") || errStr.contains("重试耗尽") || errStr.contains("socket") || errStr.contains("connection")) {
            AppLogger.log("⏸️ 检测到系统休眠或网络中断！保护机制已触发，进度安全冻结于: 第 $_activePage 页。", isError: true);
            if (mounted) {
                setState(() => _isProcessingQueue = false); // 终止循环任务
            }
            return; // 直接退出 while 循环，不清理 `_activeFile`
        } else {
            // 如果是真正的解析失败（文件损坏、不存在等），抛弃文件继续前进
            AppLogger.log("❌ 解析发生致命异常，放弃当前文件: $e", isError: true);
            if (mounted) setState(() => _textController.text += "\n[文件 ${path.basename(filePath)} 致命异常: $e]");
            _activeFile = null;
            _activePage = 0;
            _processedFilesCount++;
        }
      }

      await Future.delayed(const Duration(milliseconds: 100)); // 让出事件循环
    }

    if (mounted) {
      setState(() => _isProcessingQueue = false);
      AppLogger.log("✅ 队列中所有文件已全部映射到知识库完成。");
    }
  }

  void _addFilesToQueue(List<io.File> files) {
    if (files.isEmpty) return;
    setState(() {
      _pendingPaths.addAll(files.map((f) => f.path));
      _totalFilesToProcess += files.length;
      if (!_isLogPanelExpanded) _isLogPanelExpanded = true;
    });
    AppLogger.log("📥 队列新增 ${files.length} 个任务，当前队列积压 ${_pendingPaths.length} 个任务");
    _scrollToBottom();
    _processFileQueue(); // 尝试启动或激活消费者
  }

  Future<void> _pickFiles() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom, 
      allowedExtensions: ['txt', 'md', 'json', 'csv', 'png', 'jpg', 'jpeg', 'pdf', 'doc', 'docx'],
      allowMultiple: true, 
    );
    if (result != null) {
      _addFilesToQueue(result.paths.where((p) => p != null).map((p) => io.File(p!)).toList());
    }
  }

  Future<void> _pickFolder() async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
    if (selectedDirectory != null) {
      AppLogger.log("📂 正在扫描目录结构: $selectedDirectory");
      final dir = io.Directory(selectedDirectory);
      final validExts = ['.txt', '.md', '.json', '.csv', '.png', '.jpg', '.jpeg', '.pdf', '.doc', '.docx'];
      
      List<io.File> collectedFiles = [];
      try {
        final stream = dir.list(recursive: true, followLinks: false);
        await for (var entity in stream) {
          if (entity is io.File) {
            String ext = path.extension(entity.path).toLowerCase();
            if (validExts.contains(ext)) collectedFiles.add(entity);
          }
        }
        _addFilesToQueue(collectedFiles);
      } catch (e) {
        AppLogger.log("⚠️ 目录扫描异常: $e", isError: true);
      }
    }
  }

  // [修复] 具备内存安全与断点续传能力的 PDF 解析
  Future<void> _parsePdfWithOCR(String filePath, int startPage, Function(int page, int total, String text) onPage) async {
    final check = await io.Process.run('which', ['pdftoppm']);
    if (check.exitCode != 0) throw Exception("缺少 Linux 原生 PDF 依赖。");

    io.Directory? tempDir;
    try {
      tempDir = await io.Directory.systemTemp.createTemp('ai_teacher_pdf_');
      await io.Process.run('pdftoppm',['-png', '-r', '150', filePath, '${tempDir.path}/page']);

      final files = tempDir.listSync().whereType<io.File>().where((f) => f.path.endsWith('.png')).toList();
      files.sort((a, b) => a.path.compareTo(b.path));

      // 完美从上次死掉/休眠的 startPage 恢复，跳过已处理的页面
      for (int i = startPage; i < files.length; i++) {
        if (!mounted) break; 
        
        final pageText = await DualAIService.performLocalOCR(files[i].path);
        onPage(i, files.length, "\n[第${i+1}页提取]:\n$pageText\n");
        
        if (i < files.length - 1) await Future.delayed(const Duration(seconds: 1));
      }
    } finally {
      // 核心修复：即使中途因为休眠爆出重试异常，也会确保系统缓存被清理
      if (tempDir != null && await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  // [修改目标] 仅保存知识库不触发大模型出题，使用缓冲区全量数据
  void _saveOnly() async {
    String fullText = _knowledgeTextBuffer.toString();
    if (_topicController.text.trim().isEmpty || fullText.trim().isEmpty) return;

    setState(() {
      _isSavingDB = true;
      _saveProgress = 0.05;
      _saveStatus = "正在仅存入知识库并构建向量树...";
    });

    // 1. 创建空题目的存根数据
    final newExam = SavedExam(
      title: _topicController.text.trim(),
      examJson: "[]", // 空试卷
      knowledgeBase: fullText,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    int examId = await DatabaseHelper.saveExam(newExam);

    // 2. 如果开启了 Embedding 则直接构建向量树
    final embeddingModel = await ConfigService.getEmbeddingModel();
    if (embeddingModel.isNotEmpty) {
      await SemanticRetrievalService.buildAndSaveIndex(
        examId, fullText,
        onProgress: (status, progress) {
          if (mounted) setState(() { _saveStatus = status; _saveProgress = progress; });
        }
      );
    }

    if (mounted) {
      setState(() => _isSavingDB = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("✅ 知识库及其向量索引已成功保存")));
      Navigator.pop(context); // 返回上一页
    }
  }

  // [修改目标] 提交核心调度枢纽，使用缓冲区全量数据
  void _submitTask() async {
    String fullText = _knowledgeTextBuffer.toString();
    if (_topicController.text.trim().isEmpty || fullText.trim().isEmpty) return;
    
    if (_isEditMode) {
      //[修复-问题4] 设置知识库热更新的持久化状态栏
      setState(() {
        _isSavingDB = true; // [修改] 使用新的状态
        _saveProgress = 0.05;
        _saveStatus = "准备持久化知识库文本更新...";
      });
      
      // 触发持久化
      final updatedExam = SavedExam(
        id: widget.existingExam!.id,
        title: _topicController.text.trim(),
        examJson: widget.existingExam!.examJson,
        knowledgeBase: fullText,
        createdAt: widget.existingExam!.createdAt,
      );
      await DatabaseHelper.updateExam(updatedExam);

      // [新增逻辑] 覆写向量索引
      final embeddingModel = await ConfigService.getEmbeddingModel();
      if (embeddingModel.isNotEmpty) {
        AppLogger.log("触发数据库热更新，正在重建 Embedding 向量树...");
        await SemanticRetrievalService.buildAndSaveIndex(
          updatedExam.id!, fullText,
          onProgress: (status, progress) {
            if (mounted) {
              setState(() {
                _saveStatus = status;
                _saveProgress = progress;
              });
            }
          }
        );
      }
      
      if (mounted) {
        setState(() => _isSavingDB = false); // [修改] 结束新状态
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("✅ 知识库及其向量索引已成功更新")));
        Navigator.pop(context);
      }
    } else {
      // ==== 新建模式：执行出题引擎流程 ====
      final provider = context.read<ExamProvider>();
      final success = await provider.processAndGenerate(
        topic: _topicController.text.trim(), 
        rawText: fullText, 
        count: _questionCount, 
        difficulty: "中等",
        customPrompt: _customPromptController.text.trim(), // 传入 UI 中的内容
      );
      if (success && mounted) Navigator.pop(context);
    }
  }

  // ==========================================
  // UI：文件与日志控制台模块
  // ==========================================
  Widget _buildLogPanel() {
    double progress = _totalFilesToProcess > 0 ? (_processedFilesCount / _totalFilesToProcess) : 0.0;
    bool hasPendingTasks = _pendingPaths.isNotEmpty || _activeFile != null; // 判定是否有挂起任务

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
                  const Text("日志控制台与队列状态", style: TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  
                  // [修改] 增加判定挂起状态的 UI
                  if (_isSavingDB) ...[
                    // [修复-问题4] 显示专用的数据库进度条
                    SizedBox(width: 100, child: LinearProgressIndicator(value: _saveProgress)),
                    const SizedBox(width: 12),
                    Text(
                      _saveStatus,
                      style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.primary)
                    ),
                  ] else if (_isProcessingQueue) ...[
                    SizedBox(width: 100, child: LinearProgressIndicator(value: progress)),
                    const SizedBox(width: 12),
                    Text(
                      "流水线运行中: $_processedFilesCount/$_totalFilesToProcess", 
                      style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.primary)
                    ),
                  ] else if (hasPendingTasks) ...[
                    // 这里会展示因为休眠而被挂起的进度
                    const Icon(Icons.pause_circle_filled, size: 16, color: Colors.orange),
                    const SizedBox(width: 6),
                    Text("进度已挂起 (断点: 第 $_activePage 页)", style: const TextStyle(fontSize: 12, color: Colors.orange)),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      style: FilledButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 12)),
                      onPressed: _processFileQueue, // 用户点击后从断点继续
                      child: const Text("▶️ 继续解析", style: TextStyle(fontSize: 12)),
                    )
                  ] else ...[
                    const Icon(Icons.circle, size: 10, color: Colors.green),
                    const SizedBox(width: 6),
                    Text(
                      _totalFilesToProcess > 0 ? "全部完成 ($_totalFilesToProcess)" : "引擎空闲", 
                      style: const TextStyle(fontSize: 12, color: Colors.green)
                    ),
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
                        // [修改] 提供文件和文件夹的多重入口
                        Row(
                          children: [
                            TextButton.icon(
                              icon: const Icon(Icons.create_new_folder), 
                              label: const Text("扫描文件夹"), 
                              onPressed: _pickFolder,
                            ),
                            const SizedBox(width: 8),
                            FilledButton.tonalIcon(
                              icon: const Icon(Icons.note_add), 
                              label: const Text("追加文件"), 
                              onPressed: _pickFiles,
                            ),
                          ],
                        )
                      ]
                    ),
                    const SizedBox(height: 8),
                    
                    const SizedBox(height: 16),
                    TextField(
                      controller: _textController, 
                      minLines: 15, // 提供优秀的默认视觉高度
                      maxLines: null, // [核心修改] 允许内部无限制垂直扩展滚动
                      maxLength: null, //[核心修改] 彻底解除底层字符数量限制
                      keyboardType: TextInputType.multiline,
                      decoration: InputDecoration(
                        hintText: _enableOCR 
                          ? "在此粘贴或编辑无限长的文本资料，支持导入纯文本、图片或扫描件PDF。本地系统将自动分块构建向量库..." 
                          : "在此粘贴无限长文本。多模态模型已禁用。",
                        border: const OutlineInputBorder(),
                        label: Text('总字符数: $_totalParsedChars'),
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
                      const SizedBox(height: 16),
                      // [新增] 自定义出题指令框
                      TextField(
                        controller: _customPromptController,
                        maxLines: 3, minLines: 1,
                        decoration: const InputDecoration(
                          labelText: "自定义出题指令 (选填)",
                          hintText: "例如：请多出一些关于内存管理的题目；尽量结合实际应用场景出题；不要考过于底层的API等...",
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.psychology_alt),
                        ),
                      ),
                      const SizedBox(height: 32),
                    ],

                    if (_isEditMode) ...[
                      // 编辑模式下：保存 + 手动构建向量索引
                      Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: 50,
                              child: FilledButton.icon(
                                icon: const Icon(Icons.save),
                                label: const Text("保存知识库更新"),
                                onPressed: _isProcessingQueue ? null : _submitTask,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: SizedBox(
                              height: 50,
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.storage),
                                label: const Text("手动构建向量索引"),
                                onPressed: _isProcessingQueue ? null : () async {
                                  final text = _textController.text.trim();
                                  if (text.isEmpty) {
                                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("知识库内容为空，无法构建向量索引。")));
                                    return;
                                  }
                                  final embeddingModel = await ConfigService.getEmbeddingModel();
                                  if (embeddingModel.isEmpty) {
                                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("未配置 Embedding 模型，请先前往设置页配置。")));
                                    return;
                                  }
                                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("正在构建向量索引，请稍候...")));
                                  await SemanticRetrievalService.buildAndSaveIndex(widget.existingExam!.id!, text);
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("✅ 向量索引构建完成")));
                                  }
                                },
                              ),
                            ),
                          ),
                        ],
                      )
                    ] else ...[
                      Row(
                        children:[
                          Expanded(
                            child: SizedBox(
                              height: 50,
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.save),
                                label: const Text("仅保存知识库 (不出题)"),
                                onPressed: _isProcessingQueue ? null : _saveOnly,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: SizedBox(
                              height: 50,
                              child: FilledButton.icon(
                                icon: const Icon(Icons.auto_awesome),
                                label: const Text("保存知识库并生成题库"),
                                onPressed: _isProcessingQueue ? null : _submitTask,
                              ),
                            ),
                          ),
                        ],
                      )
                    ]
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

// ==========================================
// 视图层 - 配置与设置界面 (全矩阵动态渲染版)
// ==========================================
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // 定义四大算子引擎基座
  final List<Map<String, String>> _taskTypes =[
    {"id": "chat", "name": "核心推理流 (出题/评卷/诊断)"},
    {"id": "vision", "name": "视觉多模态流 (OCR图文解析)"},
    {"id": "embedding", "name": "语义降维流 (向量化/Embedding)"},
    {"id": "rerank", "name": "特征强化流 (知识 Rerank 重排序)"},
  ];

  // 状态维护矩阵
  Map<String, String> _configs = {};
  final Map<String, TextEditingController> _controllers = {};
  bool _enableRerank = false;
  bool _isLoading = true;

  @override 
  void initState() { 
    super.initState(); 
    _loadAllConfigs(); 
  }

  @override
  void dispose() {
    _controllers.values.forEach((c) => c.dispose());
    super.dispose();
  }

  Future<void> _loadAllConfigs() async {
    _enableRerank = await ConfigService.getEnableRerank();
    
    for (var task in _taskTypes) {
      String t = task['id']!;
      _configs['${t}_engine'] = await ConfigService.getConfigString('${t}_engine', 'cloud');
      
      for (String env in ['cloud', 'local']) {
        for (String field in['url', 'key', 'model']) {
          String mapKey = '${t}_${env}_$field';
          String val = await ConfigService.getConfigString(mapKey, '');
          _configs[mapKey] = val;
          _controllers[mapKey] = TextEditingController(text: val);
        }
      }
    }
    setState(() => _isLoading = false);
  }
  
  Future<void> _saveAllConfigs() async {
    await ConfigService.setEnableRerank(_enableRerank);
    
    for (var task in _taskTypes) {
      String t = task['id']!;
      await ConfigService.setConfigString('${t}_engine', _configs['${t}_engine']!);
      
      for (String env in ['cloud', 'local']) {
        for (String field in ['url', 'key', 'model']) {
          String mapKey = '${t}_${env}_$field';
          await ConfigService.setConfigString(mapKey, _controllers[mapKey]!.text.trim());
        }
      }
    }
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("✅ 拓扑路由矩阵已持久化存储并生效")));
  }

  Widget _buildTaskSection(Map<String, String> task) {
    String t = task['id']!;
    String currentEngine = _configs['${t}_engine'] ?? 'cloud';

    return Card(
      elevation: 2, margin: const EdgeInsets.only(bottom: 24),
      child: ExpansionTile(
        initiallyExpanded: t == 'chat',
        title: Text(task['name']!, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text("当前路由节点: ${currentEngine == 'cloud' ? '☁️ 云端外部 API' : '💻 本地私有化节点'}"),
        children:[
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children:[
                if (t == 'rerank') ...[
                  SwitchListTile(
                    title: const Text("主开关：全局启用 Rerank 机制提升特征命中率", style: TextStyle(color: Colors.indigo, fontWeight: FontWeight.bold)),
                    value: _enableRerank,
                    onChanged: (v) => setState(() => _enableRerank = v),
                  ),
                  const Divider(),
                ],
                
                Row(
                  children:[
                    const Text("业务节点切换："),
                    Radio<String>(value: "cloud", groupValue: currentEngine, onChanged: (v) => setState(() => _configs['${t}_engine'] = v!)),
                    const Text("☁️ 云端接口"),
                    const SizedBox(width: 16),
                    Radio<String>(value: "local", groupValue: currentEngine, onChanged: (v) => setState(() => _configs['${t}_engine'] = v!)),
                    const Text("💻 本地接口 (LM-Studio等)"),
                  ],
                ),
                const SizedBox(height: 16),
                
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceVariant, borderRadius: BorderRadius.circular(8), border: Border.all(color: currentEngine == 'cloud' ? Colors.blue.withOpacity(0.5) : Colors.transparent)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children:[
                      const Text("☁️ 云端参数映射", style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 12),
                      TextField(controller: _controllers['${t}_cloud_url'], decoration: const InputDecoration(labelText: "API Base URL (例: https://api.deepseek.com/v1)", border: OutlineInputBorder(), isDense: true)),
                      const SizedBox(height: 12),
                      TextField(controller: _controllers['${t}_cloud_key'], obscureText: true, decoration: const InputDecoration(labelText: "API Key (Bearer Token)", border: OutlineInputBorder(), isDense: true)),
                      const SizedBox(height: 12),
                      TextField(controller: _controllers['${t}_cloud_model'], decoration: const InputDecoration(labelText: "模型标识 (Model ID)", border: OutlineInputBorder(), isDense: true)),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceVariant, borderRadius: BorderRadius.circular(8), border: Border.all(color: currentEngine == 'local' ? Colors.green.withOpacity(0.5) : Colors.transparent)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children:[
                      const Text("💻 本地私有化参数映射", style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 12),
                      TextField(controller: _controllers['${t}_local_url'], decoration: const InputDecoration(labelText: "LM-Studio / Ollama Base URL", border: OutlineInputBorder(), isDense: true)),
                      const SizedBox(height: 12),
                      TextField(controller: _controllers['${t}_local_key'], decoration: const InputDecoration(labelText: "预留 API Key (通常填 lm-studio 即可)", border: OutlineInputBorder(), isDense: true)),
                      const SizedBox(height: 12),
                      TextField(controller: _controllers['${t}_local_model'], decoration: const InputDecoration(labelText: "挂载模型标识 (Model ID)", border: OutlineInputBorder(), isDense: true)),
                    ],
                  ),
                ),
              ],
            ),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      appBar: AppBar(title: const Text("多维网关矩阵映射与控制中心")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24), 
        child: Column(
          children:[
            const Text("每一个独立引擎均支持在本地私有算力与外部云端 API 之间自由切换，实现架构层解耦。", style: TextStyle(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 24),
            
            ..._taskTypes.map((t) => _buildTaskSection(t)).toList(),
            
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity, height: 60,
              child: FilledButton.icon(icon: const Icon(Icons.save), label: const Text("校验并存储拓扑矩阵", style: TextStyle(fontSize: 16)), onPressed: _saveAllConfigs),
            ),
            const SizedBox(height: 48),
        ]),
      ),
    );
  }
}

// ==========================================
// 重新生成考题配置对话框
// ==========================================
class _RegenerateExamDialog extends StatefulWidget {
  final SavedExam exam;
  final Function(String topic, int count, String difficulty, bool useEmbedding) onStart;
  const _RegenerateExamDialog({required this.exam, required this.onStart});

  @override
  State<_RegenerateExamDialog> createState() => _RegenerateExamDialogState();
}

class _RegenerateExamDialogState extends State<_RegenerateExamDialog> {
  late TextEditingController _topicCtrl;
  late int _count;
  late String _difficulty;
  late bool _useEmbedding;

  @override
  void initState() {
    super.initState();
    _topicCtrl = TextEditingController(text: widget.exam.title);
    _count = widget.exam.parsedQuestions.length;
    _difficulty = "中等";
    _useEmbedding = false;
  }

  @override
  void dispose() {
    _topicCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("重新生成考题配置"),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _topicCtrl,
                decoration: const InputDecoration(labelText: "出题方向", border: OutlineInputBorder()),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                value: _count,
                decoration: const InputDecoration(labelText: "出题个数", border: OutlineInputBorder()),
                items: [3, 5, 10, 15, 20].map((e) => DropdownMenuItem(value: e, child: Text("$e 题"))).toList(),
                onChanged: (v) => setState(() => _count = v!),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: _difficulty,
                decoration: const InputDecoration(labelText: "出题难度", border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: "简单", child: Text("简单")),
                  DropdownMenuItem(value: "中等", child: Text("中等")),
                  DropdownMenuItem(value: "困难", child: Text("困难")),
                ],
                onChanged: (v) => setState(() => _difficulty = v!),
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                title: const Text("使用向量化检索"),
                subtitle: const Text("开启后将基于 Embedding 模型从知识库中提取最相关片段出题"),
                value: _useEmbedding,
                onChanged: (v) => setState(() => _useEmbedding = v),
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("取消")),
        FilledButton(
          onPressed: () {
            widget.onStart(_topicCtrl.text.trim(), _count, _difficulty, _useEmbedding);
          },
          child: const Text("开始生成"),
        ),
      ],
    );
  }
}

// ==========================================
// [新增] 附加视图层 - 向量搜索与数据提取器
// ==========================================
class VectorSearchDialog extends StatefulWidget {
  final SavedExam exam;
  const VectorSearchDialog({super.key, required this.exam});

  @override
  State<VectorSearchDialog> createState() => _VectorSearchDialogState();
}

class _VectorSearchDialogState extends State<VectorSearchDialog> {
  final TextEditingController _queryCtrl = TextEditingController();
  bool _isSearching = false;
  List<String> _results =[];

  void _search() async {
    if (_queryCtrl.text.trim().isEmpty) return;
    setState(() { _isSearching = true; _results =[]; });
    
    try {
      final chunks = await SemanticRetrievalService.searchContext(widget.exam.id!, _queryCtrl.text.trim());
      setState(() => _results = chunks);
    } catch (e) {
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("检索异常: $e")));
    } finally {
      if(mounted) setState(() => _isSearching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("知识库底层向量片段提取"),
      content: SizedBox(
        width: 600, height: 400,
        child: Column(
          children: [
            Row(
              children:[
                Expanded(child: TextField(
                  controller: _queryCtrl,
                  decoration: const InputDecoration(hintText: "输入想要提取的数据关键词或意图...", border: OutlineInputBorder()),
                  onSubmitted: (_) => _search(),
                )),
                const SizedBox(width: 8),
                IconButton(icon: _isSearching ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.search), onPressed: _isSearching ? null : _search)
              ]
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _results.isEmpty 
                ? const Center(child: Text("暂无数据，请输入关键词检索"))
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (ctx, i) {
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children:[
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children:[
                                  Text("片段 ${i+1}", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                                  IconButton(
                                    icon: const Icon(Icons.copy, size: 16),
                                    onPressed: () {
                                      Clipboard.setData(ClipboardData(text: _results[i]));
                                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("该片段已复制到剪贴板")));
                                    }
                                  )
                                ]
                              ),
                              const Divider(),
                              SelectableText(_results[i], style: const TextStyle(fontSize: 12))
                            ]
                          )
                        )
                      );
                    }
                  )
            )
          ]
        )
      ),
      actions:[
        TextButton.icon(
          icon: const Icon(Icons.copy_all), label: const Text("一键复制全部片段"),
          onPressed: () {
            if (_results.isNotEmpty) {
              Clipboard.setData(ClipboardData(text: _results.join("\n\n")));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("所有相关片段已提取并复制")));
            }
          }
        ),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text("关闭"))
      ]
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
