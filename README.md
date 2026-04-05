# AI 互动助教 - 双引擎互动出题与学情分析系统

一个基于 Flutter 的桌面端 AI 助教系统，集成了本地模型与云端大模型，支持混合题型生成、智能批改、学情分析和知识库编辑功能。

## 🚀 核心功能

### 1. 双引擎出题系统
- **本地模型引擎**：使用 LM-Studio 本地模型进行初步内容提炼和重排序
- **云端大模型引擎**：使用 DeepSeek API 进行高质量混合题型生成
- **智能题型分布**：自动生成单选、多选、填空、简答等多种题型

### 2. 智能学情分析
- **AI 实时批改**：客观题自动评分，主观题 AI 诊断
- **个性化指导**：基于历史错题生成针对性学习建议
- **答题历史追踪**：完整记录每次测验的详细数据

### 3. 知识库管理
- **多格式导入**：支持文本、图片、PDF、Word 等多种格式
- **OCR 识别**：内置视觉模型自动提取图片和扫描件中的文字
- **知识库编辑**：可随时编辑原始参考资料，支持 DAG 图生成辅助理解

### 4. 新增功能（最新版本）
- **知识库编辑界面**：新增 `KnowledgeEditScreen` 组件，支持编辑已保存的知识库
- **DAG 图生成**：利用 AI 将复杂文本转换为 Mermaid 格式的有向无环图，辅助理解知识结构
- **数据库更新**：新增 `updateExam` 方法，支持知识库的持久化更新

## 🛠️ 技术架构

### 前端框架
- **Flutter 3.x**：跨平台桌面应用开发
- **Material Design 3**：现代化 UI 设计
- **Provider**：状态管理

### 后端服务
- **SQLite**：本地数据存储（支持版本迁移）
- **Dio**：HTTP 客户端
- **sqflite_common_ffi**：桌面端 SQLite 支持

### AI 集成
- **DeepSeek API**：云端大模型服务
- **LM-Studio**：本地模型服务（支持多种模型）
- **OCR 视觉模型**：图片文字识别

### 文件处理
- **FilePicker**：多格式文件选择
- **PDF 解析**：原生 PDF 引擎支持
- **图片处理**：Base64 编码与传输

## 📦 安装与运行

### 环境要求
- Flutter 3.0+
- Dart 3.0+
- Linux 桌面环境（支持 Windows/macOS）

### 安装步骤
```bash
# 克隆项目
git clone https://github.com/dpineer/question_researcher.git
cd question_researcher

# 安装依赖
flutter pub get

# 运行应用（Linux 桌面）
flutter run -d linux --debug
```

### 配置说明
首次运行前需要在设置页面配置：
1. **DeepSeek API Key**：用于云端大模型服务
2. **LM-Studio URL**：本地模型服务地址（默认：http://localhost:1234/v1）
3. **模型标识符**：根据 LM-Studio 加载的模型配置

## 🎯 使用指南

### 1. 创建题库
1. 点击首页右下角"导入资料制卷"按钮
2. 输入出题方向（如"计算机网络基础"）
3. 导入知识资料（支持文本粘贴或文件批量导入）
4. 设置题量和难度，点击"双流引擎开始生成"

### 2. 进行测验
1. 在首页题库列表中选择要测试的题库
2. 按顺序答题，支持单选、多选、填空、简答
3. 完成所有题目后提交评卷

### 3. 查看分析报告
1. 提交后自动跳转到 AI 诊断报告页面
2. 查看每道题的详细解析和 AI 诊断
3. 可查看历史答题记录和个性化指导

### 4. 编辑知识库（新增功能）
1. 在首页题库列表中点击"编辑原始知识库"按钮（绿色编辑图标）
2. 进入编辑页面修改原始参考资料
3. 点击"保存并覆盖"保存修改
4. 点击"AI 辅助理解：生成逻辑 DAG 图"按钮，生成知识结构图

## 🔧 新增功能详解

### KnowledgeEditScreen 组件
- **功能**：编辑已保存题库的原始知识库
- **位置**：首页题库列表的编辑按钮
- **特性**：
  - 全屏文本编辑器
  - 实时保存功能
  - DAG 图生成辅助理解

### DAG 图生成
- **功能**：将复杂文本转换为可视化知识图谱
- **技术**：基于 Mermaid graph TD 语法
- **使用**：
  1. 在编辑页面点击"生成逻辑 DAG 图"
  2. 等待 AI 分析文本结构
  3. 查看生成的 Mermaid 代码
  4. 可复制代码到支持 Mermaid 的渲染器查看

### DatabaseHelper.updateExam 方法
- **功能**：更新已保存的测验数据
- **用途**：主要用于修改知识库原始文本
- **调用**：在 `KnowledgeEditScreen._saveChanges()` 中调用

## 📁 项目结构

```
lib/main.dart                    # 主应用文件（包含所有组件）
├── 数据层
│   ├── DatabaseHelper          # SQLite 数据库操作
│   ├── SavedExam              # 题库实体
│   ├── ExamQuestion           # 题目实体
│   └── ExamRecord             # 答题记录实体
├── 服务层
│   └── DualAIService          # 双模型 AI 服务
├── 状态管理
│   ├── ExamProvider           # 出题状态管理
│   ├── ExamTakingProvider     # 答题状态管理
│   └── ThemeProvider          # 主题管理
└── 视图层
    ├── HomeScreen             # 首页
    ├── KnowledgeInputScreen   # 知识导入页面
    ├── ExamTakingScreen       # 答题页面
    ├── ExamResultScreen       # 结果页面
    ├── ExamHistoryScreen      # 历史记录页面
    ├── SettingsScreen         # 设置页面
    └── KnowledgeEditScreen    # 知识库编辑页面（新增）
```

## ⚙️ 配置参数

### 云端模型配置
- **DeepSeek API Key**：必需，用于高质量题目生成和诊断
- **模型**：deepseek-chat

### 本地模型配置
- **LM-Studio URL**：可选，用于本地内容提炼
- **文本提炼模型**：chat model ID
- **视觉解析模型**：vision model ID
- **重排序模型**：rerank model ID（可选）
- **嵌入模型**：embedding model ID（可选）

### 功能开关
- **启用重排序**：优化内容结构，提升出题质量

## 🐛 故障排除

### 常见问题
1. **API Key 未配置**：在设置页面配置 DeepSeek API Key
2. **本地模型连接失败**：检查 LM-Studio 是否运行在 http://localhost:1234
3. **数据库迁移问题**：删除 ~/.ai_teacher/exams_v2.db 重新创建
4. **PDF 解析失败**：Linux 系统需要安装 poppler-utils：`sudo apt-get install poppler-utils`

### 日志查看
应用内置实时日志系统，可在知识导入页面底部查看详细运行日志。

## 📄 许可证

MIT License

## 🤝 贡献指南

欢迎提交 Issue 和 Pull Request！

### 开发流程
1. Fork 项目
2. 创建功能分支
3. 提交更改
4. 推送到分支
5. 创建 Pull Request

### 代码规范
- 遵循 Dart 官方代码规范
- 使用有意义的变量名和函数名
- 添加必要的注释和文档

## 📞 联系方式

- **GitHub Issues**：[问题反馈](https://github.com/dpineer/question_researcher/issues)
- **项目主页**：[question_researcher](https://github.com/dpineer/question_researcher)

---

**版本**：v2.0.0  
**更新日期**：2026年4月5日  
**主要更新**：新增知识库编辑功能和 DAG 图生成辅助理解