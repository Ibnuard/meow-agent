/// Minimal static fallback strings used by [ToolVerbalizer] when an LLM
/// verbalization call fails.
///
/// Keep this set SMALL. The verbalizer is the source of truth; this is just
/// a safety net to ensure the user always sees something readable.
///
/// Phrases are intentionally generic — they never include tool names, IDs,
/// or argument values. The verbalizer is what makes responses contextual.
class I18nFallback {
  I18nFallback._();

  /// Get a fallback phrase for [phase] in [languageCode].
  /// Falls back to English if [languageCode] is not in the bundle.
  ///
  /// Phases: 'confirm', 'success', 'cancel', 'preview', 'abort', 'error'.
  static String get(String phase, String languageCode) {
    final bundle = _bundles[languageCode] ?? _bundles['en']!;
    return bundle[phase] ?? bundle['error']!;
  }

  static const Map<String, Map<String, String>> _bundles = {
    'id': {
      'confirm': 'Saya ingin menjalankan sebuah aksi. Lanjutkan?',
      'success': 'Selesai.',
      'cancel': 'Aksi dibatalkan.',
      'preview': 'Berikut pratinjau hasilnya.',
      'abort': 'Saya berhenti — sepertinya saya berputar pada langkah yang sama. Coba ulangi atau ubah permintaannya.',
      'error': 'Terjadi kesalahan saat memproses permintaan.',
    },
    'en': {
      'confirm': 'I want to run an action. Proceed?',
      'success': 'Done.',
      'cancel': 'Action cancelled.',
      'preview': "Here's a preview of the result.",
      'abort': "I'm stopping — I seem to be looping on the same step. Try rephrasing or breaking it down.",
      'error': 'Something went wrong while handling that request.',
    },
    'ja': {
      'confirm': '操作を実行してもよろしいですか？',
      'success': '完了しました。',
      'cancel': '操作をキャンセルしました。',
      'preview': '結果のプレビューはこちらです。',
      'abort': '同じ手順で繰り返しているようなので中断しました。言い換えて再度お試しください。',
      'error': '処理中にエラーが発生しました。',
    },
    'ko': {
      'confirm': '작업을 실행할까요?',
      'success': '완료했습니다.',
      'cancel': '작업이 취소되었습니다.',
      'preview': '결과 미리보기입니다.',
      'abort': '같은 단계를 반복하는 것 같아 중단했습니다. 다시 표현해 보세요.',
      'error': '요청 처리 중 오류가 발생했습니다.',
    },
    'zh': {
      'confirm': '我想执行一个操作。继续吗？',
      'success': '完成。',
      'cancel': '操作已取消。',
      'preview': '这是结果的预览。',
      'abort': '同一步骤似乎在循环，已停止。请尝试换种表述。',
      'error': '处理请求时出错。',
    },
    'es': {
      'confirm': 'Quiero ejecutar una acción. ¿Continúo?',
      'success': 'Listo.',
      'cancel': 'Acción cancelada.',
      'preview': 'Aquí tienes una vista previa del resultado.',
      'abort': 'Voy a detenerme: parece que estoy en bucle. Intenta reformular.',
      'error': 'Algo salió mal al procesar la solicitud.',
    },
    'fr': {
      'confirm': "Je voudrais exécuter une action. Je continue ?",
      'success': 'Terminé.',
      'cancel': 'Action annulée.',
      'preview': "Voici un aperçu du résultat.",
      'abort': "Je m'arrête : je semble tourner en boucle. Essayez de reformuler.",
      'error': 'Une erreur est survenue lors du traitement.',
    },
    'de': {
      'confirm': 'Ich möchte eine Aktion ausführen. Fortfahren?',
      'success': 'Fertig.',
      'cancel': 'Aktion abgebrochen.',
      'preview': 'Hier ist eine Vorschau des Ergebnisses.',
      'abort': 'Ich höre auf — ich scheine in einer Schleife zu sein. Bitte umformulieren.',
      'error': 'Bei der Verarbeitung ist ein Fehler aufgetreten.',
    },
    'pt': {
      'confirm': 'Quero executar uma ação. Continuar?',
      'success': 'Pronto.',
      'cancel': 'Ação cancelada.',
      'preview': 'Aqui está uma prévia do resultado.',
      'abort': 'Vou parar — parece que estou em loop. Tente reformular.',
      'error': 'Algo deu errado ao processar.',
    },
    'ru': {
      'confirm': 'Я хочу выполнить действие. Продолжить?',
      'success': 'Готово.',
      'cancel': 'Действие отменено.',
      'preview': 'Вот предварительный результат.',
      'abort': 'Останавливаюсь — кажется, я зациклился. Попробуйте переформулировать.',
      'error': 'Произошла ошибка при обработке запроса.',
    },
    'ar': {
      'confirm': 'أريد تنفيذ إجراء. هل أتابع؟',
      'success': 'تم.',
      'cancel': 'تم إلغاء الإجراء.',
      'preview': 'هذه معاينة للنتيجة.',
      'abort': 'سأتوقف — يبدو أنني أكرر نفس الخطوة. حاول إعادة الصياغة.',
      'error': 'حدث خطأ أثناء معالجة الطلب.',
    },
    'hi': {
      'confirm': 'मैं एक क्रिया चलाना चाहता हूँ। आगे बढ़ूँ?',
      'success': 'हो गया।',
      'cancel': 'क्रिया रद्द कर दी गई।',
      'preview': 'परिणाम का पूर्वावलोकन यहाँ है।',
      'abort': 'मैं रुक रहा हूँ — लगता है कि मैं उसी चरण पर अटका हूँ।',
      'error': 'अनुरोध संसाधित करते समय त्रुटि हुई।',
    },
    'vi': {
      'confirm': 'Tôi muốn thực hiện một hành động. Tiếp tục?',
      'success': 'Xong.',
      'cancel': 'Đã hủy hành động.',
      'preview': 'Đây là bản xem trước kết quả.',
      'abort': 'Tôi sẽ dừng — có vẻ tôi đang lặp lại cùng một bước.',
      'error': 'Đã xảy ra lỗi khi xử lý yêu cầu.',
    },
    'th': {
      'confirm': 'ฉันต้องการดำเนินการ ดำเนินการต่อหรือไม่?',
      'success': 'เสร็จแล้ว',
      'cancel': 'ยกเลิกการทำงานแล้ว',
      'preview': 'นี่คือตัวอย่างผลลัพธ์',
      'abort': 'ฉันจะหยุด — ดูเหมือนจะวนซ้ำขั้นตอนเดิม',
      'error': 'เกิดข้อผิดพลาดขณะประมวลผล',
    },
    'tr': {
      'confirm': 'Bir işlem çalıştırmak istiyorum. Devam edeyim mi?',
      'success': 'Tamamlandı.',
      'cancel': 'İşlem iptal edildi.',
      'preview': 'İşte sonucun önizlemesi.',
      'abort': 'Duruyorum — aynı adımda döngüye giriyor gibiyim.',
      'error': 'İstek işlenirken bir hata oluştu.',
    },
    'ms': {
      'confirm': 'Saya ingin menjalankan tindakan. Teruskan?',
      'success': 'Selesai.',
      'cancel': 'Tindakan dibatalkan.',
      'preview': 'Berikut adalah pratonton hasil.',
      'abort': 'Saya akan berhenti — saya kelihatan berulang pada langkah yang sama.',
      'error': 'Berlaku ralat semasa memproses permintaan.',
    },
    'he': {
      'confirm': 'אני רוצה לבצע פעולה. להמשיך?',
      'success': 'בוצע.',
      'cancel': 'הפעולה בוטלה.',
      'preview': 'הנה תצוגה מקדימה של התוצאה.',
      'abort': 'אני עוצר — נראה שאני בלולאה.',
      'error': 'אירעה שגיאה במהלך עיבוד הבקשה.',
    },
  };
}
