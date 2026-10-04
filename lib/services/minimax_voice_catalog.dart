import '../core/utils/constants.dart';

class MiniMaxVoice {
  final String id;
  final String name;
  final String category;

  const MiniMaxVoice(this.id, this.name, this.category);
}

// MiniMax China system-voice catalog, Mandarin entries 1-58.
class MiniMaxVoiceCatalog {
  static const voices = <MiniMaxVoice>[
    MiniMaxVoice('male-qn-qingse', '青涩青年', '男声'),
    MiniMaxVoice('male-qn-jingying', '精英青年', '男声'),
    MiniMaxVoice('male-qn-badao', '霸道青年', '男声'),
    MiniMaxVoice('male-qn-daxuesheng', '青年大学生', '男声'),
    MiniMaxVoice('female-shaonv', '少女', '女声'),
    MiniMaxVoice('female-yujie', '御姐', '女声'),
    MiniMaxVoice('female-chengshu', '成熟女性', '女声'),
    MiniMaxVoice('female-tianmei', '甜美女性', '女声'),
    MiniMaxVoice('male-qn-qingse-jingpin', '青涩青年 beta', '男声'),
    MiniMaxVoice('male-qn-jingying-jingpin', '精英青年 beta', '男声'),
    MiniMaxVoice('male-qn-badao-jingpin', '霸道青年 beta', '男声'),
    MiniMaxVoice('male-qn-daxuesheng-jingpin', '青年大学生 beta', '男声'),
    MiniMaxVoice('female-shaonv-jingpin', '少女 beta', '女声'),
    MiniMaxVoice('female-yujie-jingpin', '御姐 beta', '女声'),
    MiniMaxVoice('female-chengshu-jingpin', '成熟女性 beta', '女声'),
    MiniMaxVoice('female-tianmei-jingpin', '甜美女性 beta', '女声'),
    MiniMaxVoice('clever_boy', '聪明男童', '男声'),
    MiniMaxVoice('cute_boy', '可爱男童', '男声'),
    MiniMaxVoice('lovely_girl', '萌萌女童', '女声'),
    MiniMaxVoice('cartoon_pig', '卡通猪小琪', '角色'),
    MiniMaxVoice('bingjiao_didi', '病娇弟弟', '男声'),
    MiniMaxVoice('junlang_nanyou', '俊朗男友', '男声'),
    MiniMaxVoice('chunzhen_xuedi', '纯真学弟', '男声'),
    MiniMaxVoice('lengdan_xiongzhang', '冷淡学长', '男声'),
    MiniMaxVoice('badao_shaoye', '霸道少爷', '男声'),
    MiniMaxVoice('tianxin_xiaoling', '甜心小玲', '女声'),
    MiniMaxVoice('qiaopi_mengmei', '俏皮萌妹', '女声'),
    MiniMaxVoice('wumei_yujie', '妩媚御姐', '女声'),
    MiniMaxVoice('diadia_xuemei', '嗲嗲学妹', '女声'),
    MiniMaxVoice('danya_xuejie', '淡雅学姐', '女声'),
    MiniMaxVoice('Chinese (Mandarin)_Reliable_Executive', '沉稳高管', '男声'),
    MiniMaxVoice('Chinese (Mandarin)_News_Anchor', '新闻女声', '女声'),
    MiniMaxVoice('Chinese (Mandarin)_Mature_Woman', '傲娇御姐', '女声'),
    MiniMaxVoice('Chinese (Mandarin)_Unrestrained_Young_Man', '不羁青年', '男声'),
    MiniMaxVoice('Arrogant_Miss', '嚣张小姐', '女声'),
    MiniMaxVoice('Robot_Armor', '机械战甲', '角色'),
    MiniMaxVoice('Chinese (Mandarin)_Kind-hearted_Antie', '热心大婶', '女声'),
    MiniMaxVoice('Chinese (Mandarin)_HK_Flight_Attendant', '港普空姐', '女声'),
    MiniMaxVoice('Chinese (Mandarin)_Humorous_Elder', '搞笑大爷', '男声'),
    MiniMaxVoice('Chinese (Mandarin)_Gentleman', '温润男声', '男声'),
    MiniMaxVoice('Chinese (Mandarin)_Warm_Bestie', '温暖闺蜜', '女声'),
    MiniMaxVoice('Chinese (Mandarin)_Male_Announcer', '播报男声', '男声'),
    MiniMaxVoice('Chinese (Mandarin)_Sweet_Lady', '甜美女声', '女声'),
    MiniMaxVoice('Chinese (Mandarin)_Southern_Young_Man', '南方小哥', '男声'),
    MiniMaxVoice('Chinese (Mandarin)_Wise_Women', '阅历姐姐', '女声'),
    MiniMaxVoice('Chinese (Mandarin)_Gentle_Youth', '温润青年', '男声'),
    MiniMaxVoice('Chinese (Mandarin)_Warm_Girl', '温暖少女', '女声'),
    MiniMaxVoice('Chinese (Mandarin)_Kind-hearted_Elder', '花甲奶奶', '女声'),
    MiniMaxVoice('Chinese (Mandarin)_Cute_Spirit', '憨憨萌兽', '角色'),
    MiniMaxVoice('Chinese (Mandarin)_Radio_Host', '电台男主播', '男声'),
    MiniMaxVoice('Chinese (Mandarin)_Lyrical_Voice', '抒情男声', '男声'),
    MiniMaxVoice('Chinese (Mandarin)_Straightforward_Boy', '率真弟弟', '男声'),
    MiniMaxVoice('Chinese (Mandarin)_Sincere_Adult', '真诚青年', '男声'),
    MiniMaxVoice('Chinese (Mandarin)_Gentle_Senior', '温柔学姐', '女声'),
    MiniMaxVoice('Chinese (Mandarin)_Stubborn_Friend', '嘴硬竹马', '男声'),
    MiniMaxVoice('Chinese (Mandarin)_Crisp_Girl', '清脆少女', '女声'),
    MiniMaxVoice('Chinese (Mandarin)_Pure-hearted_Boy', '清澈邻家弟弟', '男声'),
    MiniMaxVoice('Chinese (Mandarin)_Soft_Girl', '柔和少女', '女声'),
  ];

  static MiniMaxVoice? find(String id) {
    for (final voice in voices) {
      if (voice.id == id) return voice;
    }
    return null;
  }

  static String validatedId(String? id) =>
      find(id ?? '')?.id ?? AppConstants.ttsVoice;
}
