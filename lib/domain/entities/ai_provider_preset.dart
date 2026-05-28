class AiProviderPreset {
  const AiProviderPreset({
    required this.id,
    required this.label,
    required this.baseUrl,
    required this.defaultModel,
    required this.description,
    required this.recommendedModels,
    this.note = '',
  });

  final String id;
  final String label;
  final String baseUrl;
  final String defaultModel;
  final String description;
  final List<String> recommendedModels;
  final String note;

  static const volcengine = AiProviderPreset(
    id: 'volcengine',
    label: '火山方舟',
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
    defaultModel: 'doubao-seed-2-0-mini-260428',
    description: '当前默认接入，适合继续沿用火山方舟兼容接口。',
    recommendedModels: ['doubao-seed-2-0-mini-260428'],
  );

  static const openRouter = AiProviderPreset(
    id: 'openrouter',
    label: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    defaultModel: 'google/gemini-2.5-flash-lite',
    description: '一套接口接多家模型，方便快速切换和横向比较。',
    recommendedModels: [
      'xiaomi/mimo-v2.5',
      'xiaomi/mimo-v2-omni',
      'qwen/qwen3-vl-8b-instruct',
      'qwen/qwen3-vl-30b-a3b-instruct',
      'z-ai/glm-4.5v',
      'z-ai/glm-5v-turbo',
      'minimax/minimax-01',
      'google/gemini-2.5-flash-lite',
      'google/gemini-2.5-flash',
      'openai/gpt-4.1-mini',
    ],
    note: '适合统一测试小米、阿里 Qwen、GLM、MiniMax 以及 Google / OpenAI 模型。',
  );

  static const xiaomiPayAsYouGo = AiProviderPreset(
    id: 'xiaomi-payg',
    label: '小米 MiMo（按量）',
    baseUrl: 'https://api.xiaomimimo.com/v1',
    defaultModel: 'mimo-v2.5',
    description: '按量计费，直接使用开放平台普通 API Key。',
    recommendedModels: ['mimo-v2.5', 'mimo-v2-omni', 'mimo-v2-flash'],
    note: '图像理解建议选 mimo-v2.5 或 mimo-v2-omni。',
  );

  static const xiaomiTokenPlan = AiProviderPreset(
    id: 'xiaomi-token-plan',
    label: '小米 MiMo（Token Plan）',
    baseUrl: 'https://token-plan-cn.xiaomimimo.com/v1',
    defaultModel: 'mimo-v2.5',
    description: '包月订阅路线，适合有持续调用量时使用。',
    recommendedModels: ['mimo-v2.5', 'mimo-v2-omni', 'mimo-v2-flash'],
    note: '需要使用 Token Plan 专属 Base URL 和 API Key。',
  );

  static const gemini = AiProviderPreset(
    id: 'gemini',
    label: 'Google Gemini',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
    defaultModel: 'gemini-2.5-flash',
    description: 'Google 官方 OpenAI 兼容入口，适合直接接入多模态。',
    recommendedModels: ['gemini-2.5-flash', 'gemini-2.5-flash-lite'],
    note: 'Google 的 OpenAI 兼容层仍在 Beta，遇到差异时优先看官方兼容文档。',
  );

  static const groq = AiProviderPreset(
    id: 'groq',
    label: 'Groq',
    baseUrl: 'https://api.groq.com/openai/v1',
    defaultModel: 'meta-llama/llama-4-scout-17b-16e-instruct',
    description: '低延迟，适合快速识别与交互式场景。',
    recommendedModels: [
      'meta-llama/llama-4-scout-17b-16e-instruct',
      'meta-llama/llama-4-maverick-17b-128e-instruct',
    ],
    note: '请确认所选模型具备视觉能力。',
  );

  static const custom = AiProviderPreset(
    id: 'custom',
    label: '自定义兼容接口',
    baseUrl: '',
    defaultModel: '',
    description: '适用于其他 OpenAI-compatible 服务商。',
    recommendedModels: [],
  );

  static const values = [
    volcengine,
    openRouter,
    xiaomiPayAsYouGo,
    xiaomiTokenPlan,
    gemini,
    groq,
    custom,
  ];

  static AiProviderPreset fromId(String id) {
    return values.firstWhere((preset) => preset.id == id, orElse: () => custom);
  }
}
