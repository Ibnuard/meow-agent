/// Centralized phrase registry for runtime-generated strings that need to
/// adapt to the user's language without hardcoded `if (code == 'id')` checks.
///
/// This is the source of truth for short, deterministic phrases the runtime
/// emits when an LLM verbalizer is not appropriate (e.g. preflight clarify,
/// permission denied template, task abort heads-up).
///
/// Two design rules:
/// - Every supported language MUST cover every phase. Missing keys fall back
///   to English.
/// - Phrases support `{placeholder}` substitution via [phrase].
///
/// For longer, contextual replies (success, abort with reasoning) use the
/// LLM-driven `ToolVerbalizer` instead — it produces more natural copy.
class LanguageRegistry {
  LanguageRegistry._();

  /// Resolves a phrase for [phase] in [code], substituting `{key}` with
  /// values from [params].
  ///
  /// - Unknown [code] → falls back to English entry.
  /// - Unknown [phase] → falls back to a generic error phrase.
  /// - Missing placeholder values are silently kept as-is.
  static String phrase(
    String phase,
    String code, [
    Map<String, String> params = const {},
  ]) {
    final bundle = _bundles[code] ?? _bundles[_fallbackCode]!;
    final raw = bundle[phase] ?? _bundles[_fallbackCode]![phase] ?? _genericError;
    if (params.isEmpty) return raw;
    var out = raw;
    params.forEach((key, value) {
      out = out.replaceAll('{$key}', value);
    });
    return out;
  }

  /// True if [code] has its own translations (else English fallback is used).
  static bool isSupported(String code) => _bundles.containsKey(code);

  /// All language codes registered.
  static Iterable<String> get supportedCodes => _bundles.keys;

  static const _fallbackCode = 'en';
  static const _genericError = 'Something went wrong while handling that request.';

  /// Phase keys covered:
  /// - confirm, success, cancel, preview, abort, error  (legacy I18nFallback)
  /// - clarify_target_unverified  ({names})
  /// - clarify_target_no_eligible ({names})
  /// - clarify_target_unknown
  /// - block_no_targets
  /// - permission_denied         ({action}, {module}, {setting})
  /// - permission_denied_no_setting ({action}, {module})
  /// - permission_module_default
  /// - permission_action_default
  /// - task_aborted_heads_up     ({previous})
  /// - task_aborted_heads_up_unknown
  /// - completion_unverified     ({entity})
  /// - completion_unverified_generic
  /// - recovery_giving_up        ({reason})
  static const Map<String, Map<String, String>> _bundles = {
    'id': {
      'confirm': 'Saya ingin menjalankan sebuah aksi. Lanjutkan?',
      'success': 'Selesai.',
      'cancel': 'Aksi dibatalkan.',
      'preview': 'Berikut pratinjau hasilnya.',
      'abort': 'Saya berhenti — sepertinya saya berputar pada langkah yang sama. Coba ulangi atau ubah permintaannya.',
      'error': 'Terjadi kesalahan saat memproses permintaan.',
      'clarify_target_unverified':
          'Aku belum bisa memastikan target ini: {names}. Mau pakai target yang mana?',
      'clarify_target_no_eligible':
          'Tidak ada target valid yang bisa aku kerjakan. Target yang dilewati: {names}.',
      'clarify_target_unknown':
          'Aku belum bisa memastikan target yang dimaksud. Target mana yang mau dipakai?',
      'block_no_targets':
          'Tidak ada target valid yang bisa aku kerjakan dari permintaan ini.',
      'permission_denied':
          'Aku belum bisa {action} karena {module} dimatikan. Aktifkan dulu pengaturan {setting} ya.',
      'permission_denied_no_setting':
          'Aku belum bisa {action} karena {module} dimatikan.',
      'permission_module_default': 'modul terkait',
      'permission_action_default': 'menjalankan aksi itu',
      'task_aborted_heads_up':
          'Tugas sebelumnya ("{previous}") aku tunda dulu — kita lanjut yang baru.',
      'task_aborted_heads_up_unknown':
          'Tugas sebelumnya aku tunda dulu — kita lanjut yang baru.',
      'completion_unverified':
          'Aku perlu cek ulang — {entity} belum terlihat di sistem. Coba lagi sebentar.',
      'completion_unverified_generic':
          'Aku perlu cek ulang — hasilnya belum terverifikasi di sistem.',
      'recovery_giving_up':
          'Aku sudah coba beberapa cara tapi belum berhasil ({reason}). Mau pakai pendekatan lain?',
      'recovery_reason_tool_failed': 'aksinya gagal',
      'recovery_reason_verification_unverified': 'hasil belum terverifikasi',
      'recovery_reason_stuck_loop': 'aku berulang di langkah yang sama',
      'recovery_reason_unknown': 'belum ketemu jalannya',
      'context_title': '🧠 Memori {agent}',
      'context_headline_low': 'masih sangat lega, baru terpakai {pct}%',
      'context_headline_comfortable':
          'masih nyaman, sekitar {pct}% terpakai',
      'context_headline_tight': 'mulai padat, sudah {pct}% terpakai',
      'context_headline_full':
          'hampir penuh, sudah {pct}% — sebentar lagi otomatis dirapikan',
      'context_capacity_line':
          'Dari {max} token kapasitas, sekitar {used} sedang digunakan dan {free} masih kosong.',
      'context_currently_holding': 'Apa saja yang sedang diingat:',
      'context_item_identity':
          '- Identitas kamu dan catatan personal (~{tokens} token)',
      'context_item_messages':
          '- {count} pesan percakapan terakhir (~{tokens} token)',
      'context_item_capabilities':
          '- Kemampuan yang relevan untuk topik sekarang ({used} dari {total} kemampuan, ~{tokens} token)',
      'context_savings_note':
          'Karena agen cuma membawa kemampuan yang relevan, kamu hemat sekitar {delta} token tiap pesan.',
    },
    'en': {
      'confirm': 'I want to run an action. Proceed?',
      'success': 'Done.',
      'cancel': 'Action cancelled.',
      'preview': "Here's a preview of the result.",
      'abort': "I'm stopping — I seem to be looping on the same step. Try rephrasing or breaking it down.",
      'error': 'Something went wrong while handling that request.',
      'clarify_target_unverified':
          'I cannot verify these target(s): {names}. Which target should I use?',
      'clarify_target_no_eligible':
          'There are no valid targets I can act on. Skipped target(s): {names}.',
      'clarify_target_unknown':
          'I cannot verify the requested target yet. Which target should I use?',
      'block_no_targets':
          'There are no valid targets I can act on for this request.',
      'permission_denied':
          "I can't {action} because {module} is off. Please enable {setting} first.",
      'permission_denied_no_setting':
          "I can't {action} because {module} is off.",
      'permission_module_default': 'the required module',
      'permission_action_default': 'do that',
      'task_aborted_heads_up':
          'Set the previous task ("{previous}") aside — moving on to the new one.',
      'task_aborted_heads_up_unknown':
          'Set the previous task aside — moving on to the new one.',
      'completion_unverified':
          "Let me double-check — {entity} doesn't show up in the system yet. Try again in a moment.",
      'completion_unverified_generic':
          "Let me double-check — that result isn't verified in the system yet.",
      'recovery_giving_up':
          "I've tried a few approaches but didn't get there ({reason}). Want to try a different angle?",
      'recovery_reason_tool_failed': 'the action failed',
      'recovery_reason_verification_unverified': 'the result is not verified',
      'recovery_reason_stuck_loop': 'I was looping on the same step',
      'recovery_reason_unknown': "I couldn't find a path forward",
      'context_title': '🧠 {agent}’s Memory',
      'context_headline_low': 'plenty of room, only {pct}% used',
      'context_headline_comfortable': 'comfortable, around {pct}% used',
      'context_headline_tight': 'getting tight, {pct}% used',
      'context_headline_full':
          'almost full, {pct}% used — auto-cleanup will kick in soon',
      'context_capacity_line':
          'Out of {max} tokens of capacity, about {used} are in use and {free} are free.',
      'context_currently_holding': 'What it’s currently keeping in mind:',
      'context_item_identity':
          '- Your identity and personal notes (~{tokens} tokens)',
      'context_item_messages':
          '- The last {count} messages of your conversation (~{tokens} tokens)',
      'context_item_capabilities':
          '- Capabilities relevant to the current topic ({used} of {total} skills, ~{tokens} tokens)',
      'context_savings_note':
          'Because the agent only loads skills that fit the topic, you save around {delta} tokens per message.',
    },
    'ja': {
      'confirm': '操作を実行してもよろしいですか？',
      'success': '完了しました。',
      'cancel': '操作をキャンセルしました。',
      'preview': '結果のプレビューはこちらです。',
      'abort': '同じ手順で繰り返しているようなので中断しました。言い換えて再度お試しください。',
      'error': '処理中にエラーが発生しました。',
      'clarify_target_unverified': '対象を確認できません：{names}。どれを使いますか？',
      'clarify_target_no_eligible': '実行できる対象がありません。スキップ：{names}。',
      'clarify_target_unknown': '対象が特定できません。どれを使いますか？',
      'block_no_targets': 'このリクエストに対して有効な対象がありません。',
      'permission_denied':
          '{module} が無効のため {action} できません。先に「{setting}」を有効にしてください。',
      'permission_denied_no_setting': '{module} が無効のため {action} できません。',
      'permission_module_default': '対象モジュール',
      'permission_action_default': 'その操作を実行',
      'task_aborted_heads_up': '前のタスク（"{previous}"）は保留にします。新しいタスクに進みます。',
      'task_aborted_heads_up_unknown': '前のタスクは保留にします。新しいタスクに進みます。',
      'completion_unverified':
          '確認させてください — {entity} がまだシステムに反映されていません。少し待って再度お試しを。',
      'completion_unverified_generic': '確認させてください — 結果がシステム上で未検証です。',
      'recovery_giving_up':
          'いくつか試しましたが ({reason}) 解決できませんでした。別の方法を試しますか？',
    },
    'ko': {
      'confirm': '작업을 실행할까요?',
      'success': '완료했습니다.',
      'cancel': '작업이 취소되었습니다.',
      'preview': '결과 미리보기입니다.',
      'abort': '같은 단계를 반복하는 것 같아 중단했습니다. 다시 표현해 보세요.',
      'error': '요청 처리 중 오류가 발생했습니다.',
      'clarify_target_unverified': '대상을 확인할 수 없습니다: {names}. 어떤 것을 사용할까요?',
      'clarify_target_no_eligible': '실행 가능한 대상이 없습니다. 건너뜀: {names}.',
      'clarify_target_unknown': '대상이 명확하지 않습니다. 어떤 것을 사용할까요?',
      'block_no_targets': '이 요청에 대해 실행 가능한 대상이 없습니다.',
      'permission_denied': '{module}이(가) 꺼져 있어 {action}할 수 없습니다. 먼저 "{setting}"을(를) 켜 주세요.',
      'permission_denied_no_setting': '{module}이(가) 꺼져 있어 {action}할 수 없습니다.',
      'permission_module_default': '관련 모듈',
      'permission_action_default': '해당 작업을 실행',
      'task_aborted_heads_up': '이전 작업("{previous}")은 잠시 미뤄두고 새 작업을 진행할게요.',
      'task_aborted_heads_up_unknown': '이전 작업은 미뤄두고 새 작업을 진행할게요.',
      'completion_unverified': '확인이 필요합니다 — {entity}이(가) 아직 시스템에 보이지 않습니다.',
      'completion_unverified_generic': '확인이 필요합니다 — 결과가 아직 시스템에서 확인되지 않았습니다.',
      'recovery_giving_up': '몇 가지 방법을 시도했지만 실패했습니다 ({reason}). 다른 방식을 시도할까요?',
    },
    'zh': {
      'confirm': '我想执行一个操作。继续吗？',
      'success': '完成。',
      'cancel': '操作已取消。',
      'preview': '这是结果的预览。',
      'abort': '同一步骤似乎在循环，已停止。请尝试换种表述。',
      'error': '处理请求时出错。',
      'clarify_target_unverified': '无法确认目标：{names}。你想用哪个？',
      'clarify_target_no_eligible': '没有可执行的目标。已跳过：{names}。',
      'clarify_target_unknown': '目标不明确，你想用哪个？',
      'block_no_targets': '此请求没有有效的目标可执行。',
      'permission_denied': '{module} 已关闭，无法{action}。请先启用"{setting}"。',
      'permission_denied_no_setting': '{module} 已关闭，无法{action}。',
      'permission_module_default': '相关模块',
      'permission_action_default': '执行该操作',
      'task_aborted_heads_up': '把上一个任务（"{previous}"）暂时搁置，继续新的任务。',
      'task_aborted_heads_up_unknown': '把上一个任务暂时搁置，继续新的任务。',
      'completion_unverified': '需要再确认 — {entity} 还没出现在系统里，稍等再试。',
      'completion_unverified_generic': '需要再确认 — 结果还未在系统中验证。',
      'recovery_giving_up': '试了几种方法都没成功（{reason}）。要换个思路吗？',
    },
    'es': {
      'confirm': 'Quiero ejecutar una acción. ¿Continúo?',
      'success': 'Listo.',
      'cancel': 'Acción cancelada.',
      'preview': 'Aquí tienes una vista previa del resultado.',
      'abort': 'Voy a detenerme: parece que estoy en bucle. Intenta reformular.',
      'error': 'Algo salió mal al procesar la solicitud.',
      'clarify_target_unverified':
          'No puedo verificar este(os) objetivo(s): {names}. ¿Cuál usamos?',
      'clarify_target_no_eligible':
          'No hay objetivos válidos para actuar. Omitidos: {names}.',
      'clarify_target_unknown':
          'No puedo verificar el objetivo solicitado. ¿Cuál usamos?',
      'block_no_targets': 'No hay objetivos válidos para esta solicitud.',
      'permission_denied':
          'No puedo {action} porque {module} está desactivado. Habilita "{setting}" primero.',
      'permission_denied_no_setting':
          'No puedo {action} porque {module} está desactivado.',
      'permission_module_default': 'el módulo requerido',
      'permission_action_default': 'hacer eso',
      'task_aborted_heads_up':
          'Dejo la tarea anterior ("{previous}") en pausa — sigamos con la nueva.',
      'task_aborted_heads_up_unknown':
          'Dejo la tarea anterior en pausa — sigamos con la nueva.',
      'completion_unverified':
          'Voy a comprobarlo — {entity} aún no aparece en el sistema.',
      'completion_unverified_generic':
          'Voy a comprobarlo — el resultado aún no está verificado.',
      'recovery_giving_up':
          'Probé varias formas y no funcionó ({reason}). ¿Probamos otro enfoque?',
    },
    'fr': {
      'confirm': "Je voudrais exécuter une action. Je continue ?",
      'success': 'Terminé.',
      'cancel': 'Action annulée.',
      'preview': "Voici un aperçu du résultat.",
      'abort': "Je m'arrête : je semble tourner en boucle. Essayez de reformuler.",
      'error': 'Une erreur est survenue lors du traitement.',
      'clarify_target_unverified':
          "Je ne peux pas vérifier cette/ces cible(s) : {names}. Laquelle utilisons-nous ?",
      'clarify_target_no_eligible':
          "Aucune cible valide pour agir. Ignorées : {names}.",
      'clarify_target_unknown':
          "Je ne peux pas vérifier la cible demandée. Laquelle utilisons-nous ?",
      'block_no_targets': "Aucune cible valide pour cette demande.",
      'permission_denied':
          "Je ne peux pas {action} car {module} est désactivé. Activez d'abord « {setting} ».",
      'permission_denied_no_setting':
          "Je ne peux pas {action} car {module} est désactivé.",
      'permission_module_default': 'le module requis',
      'permission_action_default': 'faire cela',
      'task_aborted_heads_up':
          'Je mets la tâche précédente (« {previous} ») de côté — passons à la nouvelle.',
      'task_aborted_heads_up_unknown':
          'Je mets la tâche précédente de côté — passons à la nouvelle.',
      'completion_unverified':
          "Je revérifie — {entity} n'apparaît pas encore dans le système.",
      'completion_unverified_generic':
          "Je revérifie — le résultat n'est pas encore confirmé.",
      'recovery_giving_up':
          "J'ai tenté plusieurs approches sans succès ({reason}). On essaie autrement ?",
    },
    'de': {
      'confirm': 'Ich möchte eine Aktion ausführen. Fortfahren?',
      'success': 'Fertig.',
      'cancel': 'Aktion abgebrochen.',
      'preview': 'Hier ist eine Vorschau des Ergebnisses.',
      'abort': 'Ich höre auf — ich scheine in einer Schleife zu sein. Bitte umformulieren.',
      'error': 'Bei der Verarbeitung ist ein Fehler aufgetreten.',
      'clarify_target_unverified':
          'Ich kann diese Ziel(e) nicht verifizieren: {names}. Welches nehmen wir?',
      'clarify_target_no_eligible':
          'Keine gültigen Ziele zur Bearbeitung. Übersprungen: {names}.',
      'clarify_target_unknown':
          'Ich kann das angefragte Ziel nicht verifizieren. Welches nehmen wir?',
      'block_no_targets': 'Keine gültigen Ziele für diese Anfrage.',
      'permission_denied':
          'Ich kann {action} nicht, weil {module} aus ist. Bitte erst „{setting}" aktivieren.',
      'permission_denied_no_setting':
          'Ich kann {action} nicht, weil {module} aus ist.',
      'permission_module_default': 'das erforderliche Modul',
      'permission_action_default': 'das tun',
      'task_aborted_heads_up':
          'Vorherige Aufgabe („{previous}") pausiere ich — wir machen mit der neuen weiter.',
      'task_aborted_heads_up_unknown':
          'Vorherige Aufgabe pausiere ich — wir machen mit der neuen weiter.',
      'completion_unverified':
          'Ich prüfe nochmal — {entity} ist im System noch nicht sichtbar.',
      'completion_unverified_generic':
          'Ich prüfe nochmal — das Ergebnis ist im System noch nicht bestätigt.',
      'recovery_giving_up':
          'Habe mehrere Wege versucht, ohne Erfolg ({reason}). Anderen Ansatz versuchen?',
    },
    'pt': {
      'confirm': 'Quero executar uma ação. Continuar?',
      'success': 'Pronto.',
      'cancel': 'Ação cancelada.',
      'preview': 'Aqui está uma prévia do resultado.',
      'abort': 'Vou parar — parece que estou em loop. Tente reformular.',
      'error': 'Algo deu errado ao processar.',
      'clarify_target_unverified':
          'Não consigo verificar esses alvos: {names}. Qual usamos?',
      'clarify_target_no_eligible':
          'Não há alvos válidos para agir. Ignorados: {names}.',
      'clarify_target_unknown':
          'Não consigo verificar o alvo solicitado. Qual usamos?',
      'block_no_targets': 'Sem alvos válidos para essa solicitação.',
      'permission_denied':
          'Não posso {action} porque {module} está desligado. Ative "{setting}" primeiro.',
      'permission_denied_no_setting':
          'Não posso {action} porque {module} está desligado.',
      'permission_module_default': 'o módulo necessário',
      'permission_action_default': 'fazer isso',
      'task_aborted_heads_up':
          'Deixo a tarefa anterior ("{previous}") em pausa — seguimos com a nova.',
      'task_aborted_heads_up_unknown':
          'Deixo a tarefa anterior em pausa — seguimos com a nova.',
      'completion_unverified':
          'Vou conferir — {entity} ainda não aparece no sistema.',
      'completion_unverified_generic':
          'Vou conferir — o resultado ainda não foi confirmado no sistema.',
      'recovery_giving_up':
          'Tentei vários caminhos sem sucesso ({reason}). Tentamos de outro jeito?',
    },
    'ru': {
      'confirm': 'Я хочу выполнить действие. Продолжить?',
      'success': 'Готово.',
      'cancel': 'Действие отменено.',
      'preview': 'Вот предварительный результат.',
      'abort': 'Останавливаюсь — кажется, я зациклился. Попробуйте переформулировать.',
      'error': 'Произошла ошибка при обработке запроса.',
      'clarify_target_unverified':
          'Не могу подтвердить цели: {names}. Какую использовать?',
      'clarify_target_no_eligible':
          'Нет подходящих целей для выполнения. Пропущены: {names}.',
      'clarify_target_unknown':
          'Не могу подтвердить запрошенную цель. Какую использовать?',
      'block_no_targets': 'Нет подходящих целей для этого запроса.',
      'permission_denied':
          'Не могу {action}: {module} выключен. Сначала включите «{setting}».',
      'permission_denied_no_setting':
          'Не могу {action}: {module} выключен.',
      'permission_module_default': 'нужный модуль',
      'permission_action_default': 'выполнить это',
      'task_aborted_heads_up':
          'Откладываю предыдущую задачу («{previous}») — переходим к новой.',
      'task_aborted_heads_up_unknown':
          'Откладываю предыдущую задачу — переходим к новой.',
      'completion_unverified':
          'Перепроверяю — {entity} ещё не видна в системе.',
      'completion_unverified_generic':
          'Перепроверяю — результат пока не подтверждён в системе.',
      'recovery_giving_up':
          'Пробовал по-разному, не получилось ({reason}). Пробуем другой подход?',
    },
    'ar': {
      'confirm': 'أريد تنفيذ إجراء. هل أتابع؟',
      'success': 'تم.',
      'cancel': 'تم إلغاء الإجراء.',
      'preview': 'هذه معاينة للنتيجة.',
      'abort': 'سأتوقف — يبدو أنني أكرر نفس الخطوة. حاول إعادة الصياغة.',
      'error': 'حدث خطأ أثناء معالجة الطلب.',
      'clarify_target_unverified': 'لا أستطيع التحقق من الأهداف: {names}. أيها نستخدم؟',
      'clarify_target_no_eligible': 'لا توجد أهداف صالحة للتنفيذ. تم تخطي: {names}.',
      'clarify_target_unknown': 'لا أستطيع التحقق من الهدف المطلوب. أيها نستخدم؟',
      'block_no_targets': 'لا توجد أهداف صالحة لهذا الطلب.',
      'permission_denied':
          'لا أستطيع {action} لأن {module} متوقف. فعّل "{setting}" أولاً.',
      'permission_denied_no_setting':
          'لا أستطيع {action} لأن {module} متوقف.',
      'permission_module_default': 'الوحدة المطلوبة',
      'permission_action_default': 'تنفيذ ذلك',
      'task_aborted_heads_up':
          'سأؤجل المهمة السابقة ("{previous}") — لنكمل المهمة الجديدة.',
      'task_aborted_heads_up_unknown':
          'سأؤجل المهمة السابقة — لنكمل المهمة الجديدة.',
      'completion_unverified':
          'سأتحقق مجددًا — {entity} لم يظهر في النظام بعد.',
      'completion_unverified_generic':
          'سأتحقق مجددًا — النتيجة لم تُؤكد في النظام بعد.',
      'recovery_giving_up':
          'جربت طرقًا عدة دون نجاح ({reason}). نجرب أسلوبًا آخر؟',
    },
    'hi': {
      'confirm': 'मैं एक क्रिया चलाना चाहता हूँ। आगे बढ़ूँ?',
      'success': 'हो गया।',
      'cancel': 'क्रिया रद्द कर दी गई।',
      'preview': 'परिणाम का पूर्वावलोकन यहाँ है।',
      'abort': 'मैं रुक रहा हूँ — लगता है कि मैं उसी चरण पर अटका हूँ।',
      'error': 'अनुरोध संसाधित करते समय त्रुटि हुई।',
      'clarify_target_unverified':
          'मैं इन लक्ष्यों की पुष्टि नहीं कर पा रहा: {names}. कौन सा इस्तेमाल करें?',
      'clarify_target_no_eligible':
          'कार्य करने योग्य लक्ष्य नहीं है। छोड़ा गया: {names}.',
      'clarify_target_unknown':
          'अनुरोधित लक्ष्य की पुष्टि नहीं हो पा रही। कौन सा इस्तेमाल करें?',
      'block_no_targets': 'इस अनुरोध के लिए मान्य लक्ष्य नहीं हैं।',
      'permission_denied':
          'मैं {action} नहीं कर सकता क्योंकि {module} बंद है। पहले "{setting}" चालू करें।',
      'permission_denied_no_setting':
          'मैं {action} नहीं कर सकता क्योंकि {module} बंद है।',
      'permission_module_default': 'संबंधित मॉड्यूल',
      'permission_action_default': 'वह क्रिया करना',
      'task_aborted_heads_up':
          'पिछला कार्य ("{previous}") फ़िलहाल छोड़ रहा हूँ — नए पर चलते हैं।',
      'task_aborted_heads_up_unknown':
          'पिछला कार्य फ़िलहाल छोड़ रहा हूँ — नए पर चलते हैं।',
      'completion_unverified':
          'मैं फिर से जाँचता हूँ — {entity} सिस्टम में अभी नहीं दिख रहा।',
      'completion_unverified_generic':
          'मैं फिर से जाँचता हूँ — परिणाम अभी सिस्टम में सत्यापित नहीं है।',
      'recovery_giving_up':
          'कई तरीके आज़माए, सफल नहीं हुआ ({reason}). दूसरा तरीका आज़माएँ?',
    },
    'vi': {
      'confirm': 'Tôi muốn thực hiện một hành động. Tiếp tục?',
      'success': 'Xong.',
      'cancel': 'Đã hủy hành động.',
      'preview': 'Đây là bản xem trước kết quả.',
      'abort': 'Tôi sẽ dừng — có vẻ tôi đang lặp lại cùng một bước.',
      'error': 'Đã xảy ra lỗi khi xử lý yêu cầu.',
      'clarify_target_unverified':
          'Tôi chưa xác minh được mục tiêu: {names}. Dùng cái nào?',
      'clarify_target_no_eligible':
          'Không có mục tiêu hợp lệ để xử lý. Đã bỏ qua: {names}.',
      'clarify_target_unknown':
          'Chưa xác minh được mục tiêu. Dùng cái nào?',
      'block_no_targets': 'Không có mục tiêu hợp lệ cho yêu cầu này.',
      'permission_denied':
          'Tôi không thể {action} vì {module} đang tắt. Hãy bật "{setting}" trước.',
      'permission_denied_no_setting':
          'Tôi không thể {action} vì {module} đang tắt.',
      'permission_module_default': 'mô-đun cần thiết',
      'permission_action_default': 'làm việc đó',
      'task_aborted_heads_up':
          'Tạm gác lại nhiệm vụ trước ("{previous}") — chuyển sang nhiệm vụ mới.',
      'task_aborted_heads_up_unknown':
          'Tạm gác lại nhiệm vụ trước — chuyển sang nhiệm vụ mới.',
      'completion_unverified':
          'Tôi kiểm tra lại — {entity} chưa xuất hiện trong hệ thống.',
      'completion_unverified_generic':
          'Tôi kiểm tra lại — kết quả chưa được xác nhận trong hệ thống.',
      'recovery_giving_up':
          'Đã thử nhiều cách nhưng chưa được ({reason}). Thử cách khác nhé?',
    },
    'th': {
      'confirm': 'ฉันต้องการดำเนินการ ดำเนินการต่อหรือไม่?',
      'success': 'เสร็จแล้ว',
      'cancel': 'ยกเลิกการทำงานแล้ว',
      'preview': 'นี่คือตัวอย่างผลลัพธ์',
      'abort': 'ฉันจะหยุด — ดูเหมือนจะวนซ้ำขั้นตอนเดิม',
      'error': 'เกิดข้อผิดพลาดขณะประมวลผล',
      'clarify_target_unverified':
          'ยังยืนยันเป้าหมายไม่ได้: {names} จะใช้อันไหนดี?',
      'clarify_target_no_eligible':
          'ไม่มีเป้าหมายที่ทำได้ ข้ามไป: {names}',
      'clarify_target_unknown': 'ยังยืนยันเป้าหมายที่ขอไม่ได้ จะใช้อันไหนดี?',
      'block_no_targets': 'ไม่มีเป้าหมายที่ทำได้สำหรับคำขอนี้',
      'permission_denied':
          'ทำ {action} ไม่ได้เพราะ {module} ปิดอยู่ เปิด "{setting}" ก่อนนะ',
      'permission_denied_no_setting':
          'ทำ {action} ไม่ได้เพราะ {module} ปิดอยู่',
      'permission_module_default': 'โมดูลที่เกี่ยวข้อง',
      'permission_action_default': 'ทำสิ่งนั้น',
      'task_aborted_heads_up':
          'พักงานเดิม ("{previous}") ไว้ก่อน — ไปต่อกับงานใหม่',
      'task_aborted_heads_up_unknown':
          'พักงานเดิมไว้ก่อน — ไปต่อกับงานใหม่',
      'completion_unverified':
          'ขอเช็คอีกที — {entity} ยังไม่ปรากฏในระบบ',
      'completion_unverified_generic':
          'ขอเช็คอีกที — ผลยังไม่ถูกยืนยันในระบบ',
      'recovery_giving_up':
          'ลองหลายวิธีแล้วไม่สำเร็จ ({reason}) เปลี่ยนวิธีดีไหม?',
    },
    'tr': {
      'confirm': 'Bir işlem çalıştırmak istiyorum. Devam edeyim mi?',
      'success': 'Tamamlandı.',
      'cancel': 'İşlem iptal edildi.',
      'preview': 'İşte sonucun önizlemesi.',
      'abort': 'Duruyorum — aynı adımda döngüye giriyor gibiyim.',
      'error': 'İstek işlenirken bir hata oluştu.',
      'clarify_target_unverified':
          'Şu hedef(ler)i doğrulayamıyorum: {names}. Hangisini kullanalım?',
      'clarify_target_no_eligible':
          'Üzerinde çalışılacak geçerli hedef yok. Atlananlar: {names}.',
      'clarify_target_unknown':
          'İstenen hedefi doğrulayamadım. Hangisini kullanalım?',
      'block_no_targets': 'Bu istek için geçerli hedef yok.',
      'permission_denied':
          '{module} kapalı olduğu için {action} yapamıyorum. Önce "{setting}" açın.',
      'permission_denied_no_setting':
          '{module} kapalı olduğu için {action} yapamıyorum.',
      'permission_module_default': 'gerekli modül',
      'permission_action_default': 'bunu yap',
      'task_aborted_heads_up':
          'Önceki görevi ("{previous}") askıya alıyorum — yenisine geçelim.',
      'task_aborted_heads_up_unknown':
          'Önceki görevi askıya alıyorum — yenisine geçelim.',
      'completion_unverified':
          'Tekrar kontrol edeyim — {entity} sistemde henüz görünmüyor.',
      'completion_unverified_generic':
          'Tekrar kontrol edeyim — sonuç henüz sistemde doğrulanmadı.',
      'recovery_giving_up':
          'Birkaç yol denedim, olmadı ({reason}). Farklı bir yaklaşım deneyelim mi?',
    },
    'ms': {
      'confirm': 'Saya ingin menjalankan tindakan. Teruskan?',
      'success': 'Selesai.',
      'cancel': 'Tindakan dibatalkan.',
      'preview': 'Berikut adalah pratonton hasil.',
      'abort': 'Saya akan berhenti — saya kelihatan berulang pada langkah yang sama.',
      'error': 'Berlaku ralat semasa memproses permintaan.',
      'clarify_target_unverified':
          'Saya tidak dapat mengesahkan sasaran: {names}. Yang mana hendak digunakan?',
      'clarify_target_no_eligible':
          'Tiada sasaran sah untuk diproses. Dilangkau: {names}.',
      'clarify_target_unknown':
          'Tidak dapat mengesahkan sasaran. Yang mana hendak digunakan?',
      'block_no_targets': 'Tiada sasaran sah untuk permintaan ini.',
      'permission_denied':
          'Saya tidak boleh {action} kerana {module} dimatikan. Aktifkan "{setting}" dahulu.',
      'permission_denied_no_setting':
          'Saya tidak boleh {action} kerana {module} dimatikan.',
      'permission_module_default': 'modul berkaitan',
      'permission_action_default': 'lakukan tindakan itu',
      'task_aborted_heads_up':
          'Tugas terdahulu ("{previous}") saya tangguhkan — teruskan dengan yang baharu.',
      'task_aborted_heads_up_unknown':
          'Tugas terdahulu saya tangguhkan — teruskan dengan yang baharu.',
      'completion_unverified':
          'Saya semak semula — {entity} belum muncul dalam sistem.',
      'completion_unverified_generic':
          'Saya semak semula — hasil belum disahkan dalam sistem.',
      'recovery_giving_up':
          'Saya cuba beberapa cara tetapi tidak berjaya ({reason}). Cuba pendekatan lain?',
    },
    'he': {
      'confirm': 'אני רוצה לבצע פעולה. להמשיך?',
      'success': 'בוצע.',
      'cancel': 'הפעולה בוטלה.',
      'preview': 'הנה תצוגה מקדימה של התוצאה.',
      'abort': 'אני עוצר — נראה שאני בלולאה.',
      'error': 'אירעה שגיאה במהלך עיבוד הבקשה.',
      'clarify_target_unverified':
          'לא הצלחתי לאמת את היעדים: {names}. במי להשתמש?',
      'clarify_target_no_eligible':
          'אין יעדים תקפים לטיפול. דולג: {names}.',
      'clarify_target_unknown':
          'לא הצלחתי לאמת את היעד המבוקש. במי להשתמש?',
      'block_no_targets': 'אין יעדים תקפים לבקשה הזו.',
      'permission_denied':
          'לא אוכל {action} כי {module} כבוי. הפעל קודם את "{setting}".',
      'permission_denied_no_setting':
          'לא אוכל {action} כי {module} כבוי.',
      'permission_module_default': 'המודול הנדרש',
      'permission_action_default': 'לבצע את הפעולה',
      'task_aborted_heads_up':
          'אני משהה את המשימה הקודמת ("{previous}") — נמשיך לחדשה.',
      'task_aborted_heads_up_unknown':
          'אני משהה את המשימה הקודמת — נמשיך לחדשה.',
      'completion_unverified':
          'אבדוק שוב — {entity} עדיין לא מופיע במערכת.',
      'completion_unverified_generic':
          'אבדוק שוב — התוצאה עדיין לא אומתה במערכת.',
      'recovery_giving_up':
          'ניסיתי כמה דרכים ולא הצלחתי ({reason}). לנסות גישה אחרת?',
    },
  };
}
