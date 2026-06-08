/// POV-AI narrative loading strings.
///
/// Goal: while the runtime is mid-flight, show a single bubble above the
/// "thinking" indicator that updates per phase so the user knows what the
/// agent is actually doing without exposing technical jargon.
///
/// Constraints:
/// - First-person, present-progressive ("I'm picking the right tool...").
/// - No tool names, no file paths, no internal state names.
/// - Localized to the user's detected language with English fallback.
/// - Static phrase bundle — zero extra LLM calls per phase change.
///
/// Phases are coarse on purpose. Sub-phases like "selecting tool retry 2"
/// collapse to the same narrative — the user does not need that detail.
class NarrativeNarrator {
  NarrativeNarrator._();

  /// Returns a POV-AI narrative for [phase] in [languageCode].
  /// Falls back to English if the language has no bundle.
  ///
  /// Recognized phases:
  /// - 'understanding'  — reading the user request
  /// - 'reflecting'     — thinking through impacts
  /// - 'asking'         — drafting a clarify question
  /// - 'planning'       — building the goal tree
  /// - 'choosing'       — picking the next tool
  /// - 'executing'      — running a tool
  /// - 'confirming'     — waiting for user approval
  /// - 'reviewing'      — checking the result
  /// - 'composing'      — writing the final reply
  /// - 'recovering'     — retrying after a hiccup
  static String narrate(String phase, String languageCode) {
    final bundle = _bundles[languageCode] ?? _bundles['en']!;
    return bundle[phase] ?? bundle['composing']!;
  }

  /// All phases this narrator knows. Useful for tests and the runtime
  /// dispatcher mapping.
  static const phases = <String>[
    'understanding',
    'reflecting',
    'asking',
    'planning',
    'choosing',
    'executing',
    'confirming',
    'reviewing',
    'composing',
    'recovering',
  ];

  static const Map<String, Map<String, String>> _bundles = {
    'id': {
      'understanding': 'Saya baca dulu apa yang kamu minta...',
      'reflecting': 'Mikir dulu ini bakal ngaruh ke mana aja...',
      'asking': 'Ada yang perlu saya tanyakan dulu...',
      'planning': 'Nyusun cara terbaik buat ngerjain ini...',
      'choosing': 'Pilih pendekatan yang paling pas...',
      'executing': 'Lagi dikerjain langkah ini...',
      'confirming': 'Butuh persetujuan kamu dulu sebelum lanjut...',
      'reviewing': 'Cek dulu hasilnya gimana...',
      'composing': 'Nyusun jawaban buat kamu...',
      'recovering': 'Tadi nggak jalan — coba cara lain...',
    },
    'en': {
      'understanding': "Let me read through what you're asking...",
      'reflecting': 'Thinking about what this might affect...',
      'asking': 'I need to check something with you first...',
      'planning': 'Working out the best way to handle this...',
      'choosing': 'Figuring out which approach fits here...',
      'executing': 'On it — running this step now...',
      'confirming': 'Need your go-ahead before I continue...',
      'reviewing': 'Let me see how that turned out...',
      'composing': 'Putting together my response...',
      'recovering': "That didn't work as expected — trying another way...",
    },
    'ja': {
      'understanding': 'ご要望を理解しています...',
      'reflecting': '影響を考えています...',
      'asking': '短い質問を準備しています...',
      'planning': '手順を整理しています...',
      'choosing': '最適な方法を選んでいます...',
      'executing': 'このステップを進めています...',
      'confirming': '確認をお待ちしています...',
      'reviewing': '結果を確認しています...',
      'composing': '返答を作成しています...',
      'recovering': '別の方法を試しています...',
    },
    'ko': {
      'understanding': '요청을 이해하고 있어요...',
      'reflecting': '영향을 검토하고 있어요...',
      'asking': '간단한 질문을 준비 중이에요...',
      'planning': '단계를 구상하고 있어요...',
      'choosing': '적절한 방법을 고르고 있어요...',
      'executing': '이 단계를 진행 중이에요...',
      'confirming': '확인을 기다리고 있어요...',
      'reviewing': '결과를 확인하고 있어요...',
      'composing': '답변을 작성하고 있어요...',
      'recovering': '다른 방법을 시도하고 있어요...',
    },
    'zh': {
      'understanding': '正在理解你的需求...',
      'reflecting': '正在评估影响...',
      'asking': '正在准备一个简短问题...',
      'planning': '正在规划步骤...',
      'choosing': '正在选择合适的方式...',
      'executing': '正在执行这一步...',
      'confirming': '等待你的确认...',
      'reviewing': '正在检查结果...',
      'composing': '正在撰写回复...',
      'recovering': '正在尝试另一种方式...',
    },
    'es': {
      'understanding': 'Entendiendo tu solicitud...',
      'reflecting': 'Considerando el impacto...',
      'asking': 'Preparando una pregunta breve...',
      'planning': 'Trazando los pasos...',
      'choosing': 'Eligiendo la mejor opción...',
      'executing': 'Trabajando en este paso...',
      'confirming': 'Esperando tu confirmación...',
      'reviewing': 'Verificando el resultado...',
      'composing': 'Redactando la respuesta...',
      'recovering': 'Probando otro enfoque...',
    },
    'fr': {
      'understanding': 'Je comprends ta demande...',
      'reflecting': "J'évalue l'impact...",
      'asking': 'Je prépare une question brève...',
      'planning': 'Je structure les étapes...',
      'choosing': 'Je choisis la meilleure approche...',
      'executing': 'Je travaille sur cette étape...',
      'confirming': "J'attends ta confirmation...",
      'reviewing': 'Je vérifie le résultat...',
      'composing': 'Je rédige la réponse...',
      'recovering': "J'essaie une autre approche...",
    },
    'de': {
      'understanding': 'Ich verstehe deine Anfrage...',
      'reflecting': 'Ich denke über die Auswirkungen nach...',
      'asking': 'Ich formuliere eine kurze Frage...',
      'planning': 'Ich plane die Schritte...',
      'choosing': 'Ich wähle den passenden Weg...',
      'executing': 'Ich arbeite an diesem Schritt...',
      'confirming': 'Ich warte auf deine Bestätigung...',
      'reviewing': 'Ich prüfe das Ergebnis...',
      'composing': 'Ich schreibe die Antwort...',
      'recovering': 'Ich versuche einen anderen Ansatz...',
    },
    'pt': {
      'understanding': 'Entendendo seu pedido...',
      'reflecting': 'Avaliando o impacto...',
      'asking': 'Preparando uma pergunta rápida...',
      'planning': 'Organizando os passos...',
      'choosing': 'Escolhendo a melhor forma...',
      'executing': 'Trabalhando neste passo...',
      'confirming': 'Aguardando sua confirmação...',
      'reviewing': 'Verificando o resultado...',
      'composing': 'Redigindo a resposta...',
      'recovering': 'Tentando outra abordagem...',
    },
    'ru': {
      'understanding': 'Понимаю запрос...',
      'reflecting': 'Обдумываю последствия...',
      'asking': 'Готовлю короткий вопрос...',
      'planning': 'Намечаю шаги...',
      'choosing': 'Выбираю подход...',
      'executing': 'Выполняю этот шаг...',
      'confirming': 'Жду подтверждения...',
      'reviewing': 'Проверяю результат...',
      'composing': 'Составляю ответ...',
      'recovering': 'Пробую другой подход...',
    },
    'ar': {
      'understanding': 'أفهم طلبك...',
      'reflecting': 'أفكر في التأثير...',
      'asking': 'أحضّر سؤالاً سريعاً...',
      'planning': 'أرسم الخطوات...',
      'choosing': 'أختار الأسلوب المناسب...',
      'executing': 'أعمل على هذه الخطوة...',
      'confirming': 'بانتظار تأكيدك...',
      'reviewing': 'أتحقق من النتيجة...',
      'composing': 'أكتب الرد...',
      'recovering': 'أجرّب طريقة أخرى...',
    },
    'hi': {
      'understanding': 'आपका अनुरोध समझ रहा हूँ...',
      'reflecting': 'प्रभाव पर विचार कर रहा हूँ...',
      'asking': 'एक छोटा सवाल तैयार कर रहा हूँ...',
      'planning': 'कदम तय कर रहा हूँ...',
      'choosing': 'सही तरीका चुन रहा हूँ...',
      'executing': 'इस चरण पर काम कर रहा हूँ...',
      'confirming': 'आपकी पुष्टि का इंतज़ार है...',
      'reviewing': 'परिणाम जाँच रहा हूँ...',
      'composing': 'जवाब तैयार कर रहा हूँ...',
      'recovering': 'दूसरा तरीका आज़मा रहा हूँ...',
    },
    'vi': {
      'understanding': 'Đang hiểu yêu cầu của bạn...',
      'reflecting': 'Đang cân nhắc ảnh hưởng...',
      'asking': 'Đang chuẩn bị câu hỏi ngắn...',
      'planning': 'Đang phác thảo các bước...',
      'choosing': 'Đang chọn cách tiếp cận...',
      'executing': 'Đang thực hiện bước này...',
      'confirming': 'Đang chờ bạn xác nhận...',
      'reviewing': 'Đang kiểm tra kết quả...',
      'composing': 'Đang soạn câu trả lời...',
      'recovering': 'Đang thử cách khác...',
    },
    'th': {
      'understanding': 'กำลังทำความเข้าใจคำขอ...',
      'reflecting': 'กำลังพิจารณาผลกระทบ...',
      'asking': 'กำลังเตรียมคำถามสั้นๆ...',
      'planning': 'กำลังวางแผนขั้นตอน...',
      'choosing': 'กำลังเลือกวิธีที่เหมาะสม...',
      'executing': 'กำลังดำเนินการขั้นตอนนี้...',
      'confirming': 'กำลังรอการยืนยัน...',
      'reviewing': 'กำลังตรวจผลลัพธ์...',
      'composing': 'กำลังเขียนคำตอบ...',
      'recovering': 'กำลังลองวิธีอื่น...',
    },
    'tr': {
      'understanding': 'İsteğini anlıyorum...',
      'reflecting': 'Etkiyi düşünüyorum...',
      'asking': 'Kısa bir soru hazırlıyorum...',
      'planning': 'Adımları planlıyorum...',
      'choosing': 'Uygun yolu seçiyorum...',
      'executing': 'Bu adım üzerinde çalışıyorum...',
      'confirming': 'Onayını bekliyorum...',
      'reviewing': 'Sonucu kontrol ediyorum...',
      'composing': 'Yanıtı hazırlıyorum...',
      'recovering': 'Farklı bir yol deniyorum...',
    },
    'ms': {
      'understanding': 'Memahami permintaan anda...',
      'reflecting': 'Menimbang kesan...',
      'asking': 'Menyediakan soalan ringkas...',
      'planning': 'Merancang langkah...',
      'choosing': 'Memilih pendekatan...',
      'executing': 'Melaksanakan langkah ini...',
      'confirming': 'Menunggu pengesahan anda...',
      'reviewing': 'Memeriksa keputusan...',
      'composing': 'Menulis jawapan...',
      'recovering': 'Mencuba cara lain...',
    },
  };
}

/// Maps a low-level [RuntimeEvent] message/state into one of the coarse
/// narrative phases recognized by [NarrativeNarrator].
///
/// Returns null when no mapping applies (e.g. internal logging events that
/// shouldn't update the user-facing narrative).
class NarrativePhaseMapper {
  NarrativePhaseMapper._();

  /// Map a runtime state name (from `AgentRuntimeState.name`) to a narrative
  /// phase key. Returns null for transitions the user shouldn't see.
  static String? phaseForState(String stateName) {
    switch (stateName) {
      case 'analyzing':
        return 'understanding';
      case 'planning':
        return 'planning';
      case 'selectingTool':
        return 'choosing';
      case 'executingTool':
        return 'executing';
      case 'waitingConfirmation':
        return 'confirming';
      case 'reviewing':
        return 'reviewing';
      case 'askingUser':
        return 'asking';
      case 'done':
      case 'failed':
        return null; // bubble destroyed by caller
      default:
        return null;
    }
  }

  /// Map a free-form runtime message hint to a phase. Used as a secondary
  /// signal for sub-phases like "Reflecting on impact and slot needs"
  /// that don't map cleanly via state name alone.
  static String? phaseForMessage(String message) {
    final m = message.toLowerCase();
    if (m.contains('reflect')) return 'reflecting';
    if (m.contains('language detected')) return 'understanding';
    if (m.contains('resuming execute loop')) return 'executing';
    if (m.contains('retry')) return 'recovering';
    return null;
  }
}
