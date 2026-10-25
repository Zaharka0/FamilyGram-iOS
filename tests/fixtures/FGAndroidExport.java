// Reference exporter: compile against the pinned, unmodified Android FamilyCore.java.
import org.telegram.messenger.family.FamilyCore;
import java.util.*;
import java.nio.charset.StandardCharsets;

public final class FGAndroidExport {
 static long clock=1;
 static ArrayList<FamilyCore.Entry> entries=new ArrayList<>();
 static FamilyCore.Entry add(String kind,String entity,long actor,String... values){
  Map<String,String> fields=FamilyCore.fields(values);
  fields.put("clock",""+clock);fields.put("nonce",String.format(Locale.US,"00000000-0000-0000-0000-%012d",clock));
  FamilyCore.Entry entry=new FamilyCore.Entry((int)clock,1000+(int)clock,actor,new FamilyCore.Op(kind,entity,fields));
  clock++;entries.add(entry);return entry;
 }
 static void value(String entity,String key,String value){
  System.out.println("STATE\t"+entity+"\t"+key+"\t"+Base64.getEncoder().encodeToString(value.getBytes(StandardCharsets.UTF_8)));
 }
 public static void main(String[]args){
  add("task","task",10,"title","Молоко 👩‍❤️‍👨","list","Покупки");
  add("task_set","task",20,"done","1"); add("task_set","task",99,"done","0");
  add("event","event",10,"title","День рождения","at","1792880000000","annual","1");
  add("event_cancel","event",20);add("event_cancel","event",10);
  add("goal","goal",10,"title","Путешествие","target","1e3");
  FamilyCore.Entry contribution=add("contribution","goal",20,"amount","12.3400");
  entries.add(new FamilyCore.Entry(500,contribution.date,20,contribution.op));
  add("contribution","goal",20,"amount","-5");add("contribution","goal",99,"amount","100");
  add("game","game",10,"mode","ttt");add("join","game",20);
  add("move","game",20,"cell","8");add("move","game",10,"cell","0");add("move","game",20,"cell","3");
  add("move","game",10,"cell","1");add("move","game",20,"cell","4");add("move","game",10,"cell","2");
  add("question_commit","q:2026-10-25",10,"hash",FamilyCore.digest("salt-a\nВместе ❤️"));
  add("question_commit","q:2026-10-25",20,"hash",FamilyCore.digest("salt-b\nДом 🏡"));
  add("question_reveal","q:2026-10-25",10,"salt","salt-a","answer","Вместе ❤️");
  add("question_reveal","q:2026-10-25",20,"salt","bad","answer","Неверный");
  add("question_reveal","q:2026-10-25",20,"salt","salt-b","answer","Дом 🏡");
  add("bookmark","bookmark",10,"text","Наш момент","message","100","ref","reference");
  add("bookmark_remove","bookmark",20);add("bookmark_remove","bookmark",10);
  add("video_presence","video",20,"joined","1");
  add("video","video",10,"message","100","position","1000","playing","1","ref","reference");
  add("video_presence","video",20,"joined","0");
  add("video","video",10,"message","100","position","5000","playing","0","ref","reference");
  add("bill","bill",10,"items","Продукты;100.01;Аня,Боря,Вика\nЧай;0.01;💛,\ue000","currency","RUB");
  add("hug","hug",20);
  for(FamilyCore.Entry e:entries)System.out.println("EVENT\t"+e.id+"\t"+e.date+"\t"+e.actor+"\t"+FamilyCore.pack(e.op));
  for(Map.Entry<String,FamilyCore.Card> item:FamilyCore.reduce(entries,10,20).entrySet()){
   String id=item.getKey();FamilyCore.Card c=item.getValue();
   value(id,"kind",c.op().kind);value(id,"done",""+c.done);value(id,"removed",""+c.removed);value(id,"saved",""+c.saved);
   value(id,"latest",c.latest.op.kind+":"+c.latest.op.get("clock"));
   if(c.game!=null){value(id,"board",new String(c.game.cells));value(id,"winner",c.game.winner==0?"":Character.toString(c.game.winner));}
   for(Map.Entry<Long,String> a:c.answers.entrySet())value(id,"answer_"+a.getKey(),a.getValue());
   for(Map.Entry<Long,FamilyCore.Entry> p:c.participants.entrySet())value(id,"presence_"+p.getKey(),p.getValue().op.get("joined"));
   if(c.op().kind.equals("bill"))for(Map.Entry<String,Long>b:FamilyCore.splitBill(c.op().get("items")).entrySet())value(id,"share_"+b.getKey(),""+b.getValue());
  }
 }
}
