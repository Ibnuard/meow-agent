import 'dart:math' as math;

/// Deterministic fallback for POV-AI narrative loading strings.
///
/// LLM phases normally provide their own `next_narrative`. This bundle keeps
/// the bubble useful when a provider omits that optional field, returns an
/// unusable response, or the runtime crosses a boundary without an LLM phase.
///
/// Constraints:
/// - First-person, present-progressive ("I'm picking the right tool...").
/// - No tool names, no file paths, no internal state names.
/// - Localized to the user's detected language with English fallback.
/// - Used only when no valid LLM-authored next-step narrative is available.
/// - Static phrase bundle — zero extra LLM calls per phase change.
///
/// Phases are coarse on purpose. Sub-phases like "selecting tool retry 2"
/// collapse to the same narrative — the user does not need that detail.
class NarrativeNarrator {
  NarrativeNarrator._();

  static final _random = math.Random();

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
    final phrases = bundle[phase] ?? bundle['composing']!;
    if (phrases.isEmpty) return '';
    return phrases[_random.nextInt(phrases.length)];
  }

  /// Describe the next runtime action before it starts.
  ///
  /// Indonesian and English have explicit future-intent phrasing. Other
  /// registered languages keep their localized progressive phrase, emitted at
  /// the pre-action boundary, rather than falling back to the wrong language.
  static String narrateNext(String phase, String languageCode) {
    final explicit = _nextBundles[languageCode]?[phase];
    if (explicit != null && explicit.isNotEmpty) {
      return explicit[_random.nextInt(explicit.length)];
    }
    return narrate(phase, languageCode);
  }

  /// Expose all possible phrases for testing.
  static List<String> allPhrasesFor(String phase, String languageCode) {
    final bundle = _bundles[languageCode] ?? _bundles['en']!;
    return bundle[phase] ?? bundle['composing'] ?? const [];
  }

  /// Expose all possible next phrases for testing.
  static List<String> allNextPhrasesFor(String phase, String languageCode) {
    final explicit = _nextBundles[languageCode]?[phase];
    if (explicit != null && explicit.isNotEmpty) {
      return explicit;
    }
    return allPhrasesFor(phase, languageCode);
  }

  /// Consistency gate for LLM-emitted narratives.
  ///
  /// LLM narrative is preserved for happy-path decisions (tool_required, done,
  /// continue, retry, direct_execute, auto_resolve). For "interrupting"
  /// decisions (ask_user, clarify, block, failed) it is overridden with a
  /// deterministic phrase from the bundle. This kills the desync where the
  /// LLM writes an optimistic narrative while the runtime is about to ask
  /// the user a clarifying question.
  static String gate({
    required String llmNarrative,
    required String decision,
    required String languageCode,
  }) {
    const interrupting = {'ask_user', 'clarify', 'block', 'failed'};
    if (!interrupting.contains(decision)) return llmNarrative;
    return narrate(_decisionToPhase(decision), languageCode);
  }

  static String _decisionToPhase(String decision) => switch (decision) {
    'ask_user' || 'clarify' => 'asking',
    'block' || 'failed' => 'recovering',
    _ => 'composing',
  };

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

  static const Map<String, Map<String, List<String>>> _nextBundles = {
    'id': {
      'reflecting': [
        'Hmm, coba kupikirkan dulu apa saja yang bakal terpengaruh...',
        'Selanjutnya, mari analisis dampak tindakan ini ke yang lain...',
        'Berikutnya, kuperiksa dulu efek samping langkah ini...',
      ],
      'asking': [
        'Akan menanyakan detail yang belum jelas ke kamu...',
        'Berikutnya, aku perlu kepastian darimu untuk beberapa info...',
        'Selanjutnya, kusiapkan pertanyaan klarifikasi dulu...',
      ],
      'planning': [
        'Mari kita buat rencana pengerjaannya...',
        'Berikutnya, aku akan menyusun langkah-langkah tugas ini...',
        'Selanjutnya, kususun urutan kerjanya dulu...',
      ],
      'choosing': [
        'Sekarang, mari cari tindakan yang cocok...',
        'Selanjutnya, kuingat-ingat dulu tindakan mana yang pas...',
        'Berikutnya, pilih aksi terbaik buat melangkah...',
      ],
      'executing': [
        'Mengeksekusi langkah terpilih sekarang...',
        'Berikutnya, mari jalankan tindakan yang sudah direncanakan...',
        'Selanjutnya, proses eksekusi dimulai...',
      ],
      'reviewing': [
        'Akan memverifikasi apakah hasilnya sudah sesuai...',
        'Berikutnya, mari cek apakah tugas selesai dengan benar...',
        'Selanjutnya, kuperiksa dulu output pengerjaannya...',
      ],
      'composing': [
        'Merangkum hasil pekerjaan untuk kamu...',
        'Berikutnya, kusiapkan rangkuman jawabannya...',
        'Selanjutnya, mari tulis laporan akhirnya...',
      ],
      'recovering': [
        'Mencoba opsi pemulihan atau cara alternatif...',
        'Berikutnya, mari coba perbaiki kendala tadi...',
        'Selanjutnya, kucari jalan keluar lain...',
      ],
    },
    'en': {
      'reflecting': [
        "Next, I'll think about what this might affect...",
        "Let's check the potential side-effects next...",
        "Next up: evaluating the impact of this move...",
      ],
      'asking': [
        "Next, I'll ask you for the missing details...",
        "Going to clarify a few things with you next...",
        "Next, I'll ask you for clarification...",
      ],
      'planning': [
        "Next, I'll lay out the required steps...",
        "Let's work out the game plan next...",
        "Next, I'll draft the step sequence...",
      ],
      'choosing': [
        "Next, I'll pick the right action for this step...",
        "Let's choose the best action for the job next...",
        "Next, I'll decide which approach to use...",
      ],
      'executing': [
        "Next, I'll run the chosen step...",
        "Going to execute this action next...",
        "Next up: starting the execution of this step...",
      ],
      'reviewing': [
        "Next, I'll verify how the output looks...",
        "Let's check the result of that action next...",
        "Next, I'll inspect the outcome...",
      ],
      'composing': [
        "Next, I'll summarize the results for you...",
        "Going to write down the final summary next...",
        "Next up: drafting the response...",
      ],
      'recovering': [
        "Next, I'll try a fallback approach...",
        "Let's work on recovery options next...",
        "Next, I'll look for an alternative path...",
      ],
    },
  };

  static const Map<String, Map<String, List<String>>> _bundles = {
    'id': {
      'understanding': [
        'Mencoba memahami maksud permintaanmu dulu ya...',
        'Bentar, kupahami dulu apa yang perlu kulakukan di sini...',
        'Membaca instruksimu baik-baik biar nggak salah tangkap...',
      ],
      'reflecting': [
        'Hmm, coba kupikirkan apa saja dampak dan ketergantungan dari tindakan ini...',
        'Menganalisis dulu apakah langkah ini aman dan ada efek sampingnya...',
        'Coba kupertimbangkan dampaknya ke sistem/agent lain dulu ya...',
      ],
      'asking': [
        'Ada bagian yang kurang jelas nih, aku tanya kamu dulu ya...',
        'Sepertinya aku butuh info tambahan dari kamu, sebentar...',
        'Ada detail yang menggantung, kutanyakan ke kamu dulu...',
      ],
      'planning': [
        'Mari kita susun rencana langkah demi langkah biar rapi...',
        'Menyusun strategi dan urutan kerja terbaik buat tugas ini...',
        'Merancang rencana kerja yang paling efisien dulu...',
      ],
      'choosing': [
        'Mencari cara atau tindakan yang paling tepat buat langkah ini...',
        'Hmm, menentukan tindakan mana yang paling pas buat dipakai sekarang...',
        'Memilih pendekatan terbaik untuk melanjutkan rencana...',
      ],
      'executing': [
        'Sedang menjalankan tindakannya, mohon tunggu sebentar...',
        'Menjalankan aksi yang dipilih... semoga lancar!',
        'Okey, langkah ini sedang kuproses sekarang...',
      ],
      'confirming': [
        'Butuh persetujuan darimu dulu sebelum kulanjutkan tindakan sensitif ini...',
        'Menunggu lampu hijau dari kamu untuk mengeksekusi langkah ini...',
        'Konfirmasi dulu ya, biar aman sebelum aku eksekusi...',
      ],
      'reviewing': [
        'Mari kita periksa dan verifikasi dulu hasil pengerjaannya...',
        'Memeriksa output eksekusi tadi... apakah semuanya sudah sesuai?',
        'Mengevaluasi hasilnya dulu untuk memastikan tidak ada error...',
      ],
      'composing': [
        'Semua beres! Lagi merangkum laporannya buat kamu...',
        'Menyusun respon akhir untuk menjelaskan hasilnya...',
        'Tugas selesai! Lagi mengetik rangkuman jawabannya dulu...',
      ],
      'recovering': [
        'Sepertinya ada kendala, coba kita cari jalan alternatif...',
        'Langkah tadi terhambat, tenang... kupikirkan cara pemulihannya...',
        'Ada masalah sedikit, lagi coba cari solusi atau pendekatan lain...',
      ],
    },
    'en': {
      'understanding': [
        "Let me wrap my head around what you're asking...",
        "Reading through your message to make sure I get it right...",
        "Let me carefully understand the goal here first...",
      ],
      'reflecting': [
        "Analyzing what dependencies or parts this might affect...",
        "Checking if this action is safe and what side-effects it has...",
        "Let me weigh the impacts of this step on the workspace...",
      ],
      'asking': [
        "I need to check some missing details with you first...",
        "Gathering some questions to clarify this request...",
        "Let me ask you about a few things that aren't clear yet...",
      ],
      'planning': [
        "Formulating a clean step-by-step plan to get this done...",
        "Working out the best strategy and order of operations...",
        "Mapping out the steps required for this task...",
      ],
      'choosing': [
        "Selecting the most appropriate action for this step...",
        "Figuring out which action fits this part of the plan...",
        "Choosing the best approach to proceed...",
      ],
      'executing': [
        "On it — running the selected step now...",
        "Executing the action, please hold on a moment...",
        "Processing the step... let's see how it goes...",
      ],
      'confirming': [
        "Need your go-ahead before running this sensitive action...",
        "Waiting for your approval to proceed with this step...",
        "Holding for confirmation to make sure you're okay with this...",
      ],
      'reviewing': [
        "Evaluating the output to verify our progress...",
        "Checking how that turned out... let me verify the results...",
        "Reviewing the output to make sure everything went smoothly...",
      ],
      'composing': [
        "All set! Putting together the final response for you...",
        "Summarizing the results and drafting the reply...",
        "Task done! Typing up the summary now...",
      ],
      'recovering': [
        "Encountered an issue — trying an alternative recovery path...",
        "That didn't work as expected. Let me find another way...",
        "Stepping back to figure out a recovery approach...",
      ],
    },
    'ja': {
      'understanding': ['ご要望を理解しています...'],
      'reflecting': ['影響を考えています...'],
      'asking': ['短い質問を準備しています...'],
      'planning': ['手順を整理しています...'],
      'choosing': ['最適な方法を選んでいます...'],
      'executing': ['このステップを進めています...'],
      'confirming': ['確認をお待ちしています...'],
      'reviewing': ['結果を確認しています...'],
      'composing': ['返答を作成しています...'],
      'recovering': ['別の方法を試しています...'],
    },
    'ko': {
      'understanding': ['요청을 이해하고 있어요...'],
      'reflecting': ['영향을 검토하고 있어요...'],
      'asking': ['간단한 질문을 준비 중이에요...'],
      'planning': ['단계를 구상하고 있어요...'],
      'choosing': ['적절한 방법을 고르고 있어요...'],
      'executing': ['이 단계를 진행 중이에요...'],
      'confirming': ['확인을 기다리고 있어요...'],
      'reviewing': ['결과를 확인하고 있어요...'],
      'composing': ['답변을 작성하고 있어요...'],
      'recovering': ['다른 방법을 시도하고 있어요...'],
    },
    'zh': {
      'understanding': ['正在理解你的需求...'],
      'reflecting': ['正在评估影响...'],
      'asking': ['正在准备一个简短问题...'],
      'planning': ['正在规划步骤...'],
      'choosing': ['正在选择合适的方式...'],
      'executing': ['正在执行这一步...'],
      'confirming': ['等待你的确认...'],
      'reviewing': ['正在检查结果...'],
      'composing': ['正在撰写回复...'],
      'recovering': ['正在尝试另一种方式...'],
    },
    'es': {
      'understanding': ['Entendiendo tu solicitud...'],
      'reflecting': ['Considerando el impacto...'],
      'asking': ['Preparando una pregunta breve...'],
      'planning': ['Trazando los pasos...'],
      'choosing': ['Eligiendo la mejor opción...'],
      'executing': ['Trabajando en este paso...'],
      'confirming': ['Esperando tu confirmación...'],
      'reviewing': ['Verificando el resultado...'],
      'composing': ['Redactando la respuesta...'],
      'recovering': ['Probando otro enfoque...'],
    },
    'fr': {
      'understanding': ['Je comprends ta demande...'],
      'reflecting': ["J'évalue l'impact..."],
      'asking': ['Je prépare une question brève...'],
      'planning': ['Je structure les étapes...'],
      'choosing': ['Je choisis la meilleure approche...'],
      'executing': ['Je travaille sur cette étape...'],
      'confirming': ["J'attends ta confirmation..."],
      'reviewing': ['Je vérifie le résultat...'],
      'composing': ['Je rédige la réponse...'],
      'recovering': ["J'essaie une autre approche..."],
    },
    'de': {
      'understanding': ['Ich verstehe deine Anfrage...'],
      'reflecting': ['Ich denke über die Auswirkungen nach...'],
      'asking': ['Ich formuliere eine kurze Frage...'],
      'planning': ['Ich plane die Schritte...'],
      'choosing': ['Ich wähle den passenden Weg...'],
      'executing': ['Ich arbeite an diesem Schritt...'],
      'confirming': ['Ich warte auf deine Bestätigung...'],
      'reviewing': ['Ich prüfe das Ergebnis...'],
      'composing': ['Ich schreibe die Antwort...'],
      'recovering': ['Ich versuche einen anderen Ansatz...'],
    },
    'pt': {
      'understanding': ['Entendendo seu pedido...'],
      'reflecting': ['Avaliando o impacto...'],
      'asking': ['Preparando uma pergunta rápida...'],
      'planning': ['Organizando os passos...'],
      'choosing': ['Escolhendo a melhor forma...'],
      'executing': ['Trabalhando neste passo...'],
      'confirming': ['Aguardando sua confirmação...'],
      'reviewing': ['Verificando o resultado...'],
      'composing': ['Redigindo a resposta...'],
      'recovering': ['Tentando outra abordagem...'],
    },
    'ru': {
      'understanding': ['Понимаю запрос...'],
      'reflecting': ['Обдумываю последствия...'],
      'asking': ['Готовлю короткий вопрос...'],
      'planning': ['Намечаю шаги...'],
      'choosing': ['Выбираю подход...'],
      'executing': ['Выполняю этот шаг...'],
      'confirming': ['Жду подтверждения...'],
      'reviewing': ['Проверяю результат...'],
      'composing': ['Составляю ответ...'],
      'recovering': ['Пробую другой подход...'],
    },
    'ar': {
      'understanding': ['أفهم طلبك...'],
      'reflecting': ['أفكر في التأثير...'],
      'asking': ['أحضّر سؤالاً سريعاً...'],
      'planning': ['أرسم الخطوات...'],
      'choosing': ['أختار الأسلوب المناسب...'],
      'executing': ['أعمل على هذه الخطوة...'],
      'confirming': ['بانتظار تأكيدك...'],
      'reviewing': ['أتحقق من النتيجة...'],
      'composing': ['أكتب الرد...'],
      'recovering': ['أجرّب طريقة أخرى...'],
    },
    'hi': {
      'understanding': ['आपका अनुरोध समझ रहा हूँ...'],
      'reflecting': ['प्रभाव पर विचार कर रहा हूँ...'],
      'asking': ['एक छोटा सवाल तैयार कर रहा हूँ...'],
      'planning': ['कदम तय कर रहा हूँ...'],
      'choosing': ['सही तरीका चुन रहा हूँ...'],
      'executing': ['इस चरण पर काम कर रहा हूँ...'],
      'confirming': ['आपकी पुष्टि का इंतज़ार है...'],
      'reviewing': ['परिणाम जाँच रहा हूँ...'],
      'composing': ['जवाब तैयार कर रहा हूँ...'],
      'recovering': ['दूसरा तरीका आज़मा रहा हूँ...'],
    },
    'vi': {
      'understanding': ['Đang hiểu yêu cầu của bạn...'],
      'reflecting': ['Đang cân nhắc ảnh hưởng...'],
      'asking': ['Đang chuẩn bị câu hỏi ngắn...'],
      'planning': ['Đang phác thảo các bước...'],
      'choosing': ['Đang chọn cách tiếp cận...'],
      'executing': ['Đang thực hiện bước này...'],
      'confirming': ['Đang chờ bạn xác nhận...'],
      'reviewing': ['Đang kiểm tra kết quả...'],
      'composing': ['Đang soạn câu trả lời...'],
      'recovering': ['Đang thử cách khác...'],
    },
    'th': {
      'understanding': ['กำลังทำความเข้าใจคำขอ...'],
      'reflecting': ['กำลังพิจารณาผลกระทบ...'],
      'asking': ['กำลังเตรียมคำถามสั้นๆ...'],
      'planning': ['กำลังวางแผนขั้นตอน...'],
      'choosing': ['กำลังเลือกวิธีที่เหมาะสม...'],
      'executing': ['กำลังดำเนินการขั้นตอนนี้...'],
      'confirming': ['กำลังรอการยืนยัน...'],
      'reviewing': ['กำลังตรวจผลลัพธ์...'],
      'composing': ['กำลังเขียนคำตอบ...'],
      'recovering': ['กำลังลองวิธีอื่น...'],
    },
    'tr': {
      'understanding': ['İsteğini anlıyorum...'],
      'reflecting': ['Etkiyi düşünüyorum...'],
      'asking': ['Kısa bir soru hazırlıyorum...'],
      'planning': ['Adımları planlıyorum...'],
      'choosing': ['Uygun yolu seçiyorum...'],
      'executing': ['Bu adım üzerinde çalışıyorum...'],
      'confirming': ['Onayını bekliyorum...'],
      'reviewing': ['Sonucu kontrol ediyorum...'],
      'composing': ['Yanıtı hazırlıyorum...'],
      'recovering': ['Farklı bir yol deniyorum...'],
    },
    'ms': {
      'understanding': ['Memahami permintaan anda...'],
      'reflecting': ['Menimbang kesan...'],
      'asking': ['Menyediakan soalan ringkas...'],
      'planning': ['Merancang langkah...'],
      'choosing': ['Memilih pendekatan...'],
      'executing': ['Melaksanakan langkah ini...'],
      'confirming': ['Menunggu pengesahan anda...'],
      'reviewing': ['Memeriksa keputusan...'],
      'composing': ['Menulis jawapan...'],
      'recovering': ['Mencuba cara lain...'],
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
