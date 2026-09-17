"""Таблица встроенных методов/свойств: тип объекта + выходной тип (OutputType).

Источник: Interpreter/DataTemplates/DefaultObjectList.cs (284 записи Objects.Add),
сгенерировано скриптом из C#-кода. Используется только для:
  * вывода типа переменной при её регистрации (VariableErrorParser.ParseInitVarError,
    ветка METHOD) — вид init-строки (`gv_x = 0` / `= ""` / `[ 0 ] = 0`);
  * GetMethodLastIndex (MethodErrorParser.cs:482) — PROPERTY не имеет скобок.

Код объекта: M=METHOD, P=PROPERTY, E=EVENT.
Значения VariableType: STRING=1, STRING_ARRAY=2, NUMBER=3, NUMBER_ARRAY=4, ANY=5, NON=0.
Формат базы: "имя=ОТТИП ..." (однострочная строка), парсится один раз в Dict.
"""

from std.collections import Dict

comptime VT_STRING = 1
comptime VT_STRING_ARRAY = 2
comptime VT_NUMBER = 3
comptime VT_NUMBER_ARRAY = 4
comptime VT_ANY = 5
comptime VT_NON = 0

comptime OBJ_METHOD = 0
comptime OBJ_PROPERTY = 1
comptime OBJ_EVENT = 2


comptime BUILTIN_OUTPUT = (
    "assert.equal=M0 " "assert.failed=M0 " "assert.greater=M0 "
    "assert.greaterequal=M0 " "assert.less=M0 " "assert.lessequal=M0 "
    "assert.near=M0 " "assert.notequal=M0 " "buttons.current=P1 "
    "buttons.flush=M0 " "buttons.getclicks=M1 " "buttons.wait=M0 "
    "byte.and_=M3 " "byte.b=M3 " "byte.bit=M3 "
    "byte.h=M3 " "byte.l=M3 " "byte.not=M3 "
    "byte.or_=M3 " "byte.shl=M3 " "byte.shr=M3 "
    "byte.tobinary=M1 " "byte.tohex=M1 " "byte.tologic=M1 "
    "byte.xor=M3 " "ev3.batterycurrent=P3 " "ev3.batterylevel=P3 "
    "ev3.batteryvoltage=P3 " "ev3.brickname=P1 " "ev3.queuenextcommand=M0 "
    "ev3.setledcolor=M0 " "ev3.systemcall=M3 " "ev3.time=P3 "
    "ev3file.close=M0 " "ev3file.converttonumber=M3 " "ev3file.openappend=M3 "
    "ev3file.openread=M3 " "ev3file.openwrite=M3 " "ev3file.readbyte=M3 "
    "ev3file.readline=M1 " "ev3file.readnumberarray=M4 " "ev3file.tablelookup=M3 "
    "ev3file.writebyte=M0 " "ev3file.writeline=M0 " "ev3file.writenumberarray=M0 "
    "lcd.bmpfile=M0 " "lcd.circle=M0 " "lcd.clear=M0 "
    "lcd.fillcircle=M0 " "lcd.fillrect=M0 " "lcd.inverserect=M0 "
    "lcd.line=M0 " "lcd.pixel=M0 " "lcd.rect=M0 "
    "lcd.stopupdate=M0 " "lcd.text=M0 " "lcd.update=M0 "
    "lcd.write=M0 " "mailbox.connect=M0 " "mailbox.create=M3 "
    "mailbox.createfornumber=M3 " "mailbox.isavailable=M1 " "mailbox.receive=M1 "
    "mailbox.receivenumber=M3 " "mailbox.send=M0 " "mailbox.sendnumber=M0 "
    "math.abs=M3 " "math.arccos=M3 " "math.arcsin=M3 "
    "math.arctan=M3 " "math.ceiling=M3 " "math.cos=M3 "
    "math.floor=M3 " "math.getdegrees=M3 " "math.getradians=M3 "
    "math.getrandomnumber=M3 " "math.log=M3 " "math.max=M3 "
    "math.min=M3 " "math.naturallog=M3 " "math.pi=P3 "
    "math.power=M3 " "math.remainder=M3 " "math.round=M3 "
    "math.sin=M3 " "math.squareroot=M3 " "math.tan=M3 "
    "motor.getcount=M3 " "motor.getspeed=M3 " "motor.invert=M0 "
    "motor.isbusy=M1 " "motor.move=M0 " "motor.movepower=M0 "
    "motor.movesteer=M0 " "motor.movesync=M0 " "motor.resetcount=M0 "
    "motor.schedule=M0 " "motor.schedulepower=M0 " "motor.schedulesteer=M0 "
    "motor.schedulesync=M0 " "motor.start=M0 " "motor.startpower=M0 "
    "motor.startsteer=M0 " "motor.startsync=M0 " "motor.stop=M0 "
    "motor.wait=M0 " "motora.getspeed=M3 " "motora.gettacho=M3 "
    "motora.islarge=M0 " "motora.ismedium=M0 " "motora.off=M0 "
    "motora.offandbrake=M0 " "motora.resetcount=M0 " "motora.setdirectpolarity=M0 "
    "motora.setpower=M0 " "motora.setreverspolarity=M0 " "motora.setspeed=M0 "
    "motora.start=M0 " "motora.startpower=M0 " "motora.startspeed=M0 "
    "motorab.off=M0 " "motorab.offandbrake=M0 " "motorab.setpower=M0 "
    "motorab.setspeed=M0 " "motorab.start=M0 " "motorab.startpower=M0 "
    "motorab.startspeed=M0 " "motorac.off=M0 " "motorac.offandbrake=M0 "
    "motorac.setpower=M0 " "motorac.setspeed=M0 " "motorac.start=M0 "
    "motorac.startpower=M0 " "motorac.startspeed=M0 " "motorad.off=M0 "
    "motorad.offandbrake=M0 " "motorad.setpower=M0 " "motorad.setspeed=M0 "
    "motorad.start=M0 " "motorad.startpower=M0 " "motorad.startspeed=M0 "
    "motorb.getspeed=M3 " "motorb.gettacho=M3 " "motorb.islarge=M0 "
    "motorb.ismedium=M0 " "motorb.off=M0 " "motorb.offandbrake=M0 "
    "motorb.resetcount=M0 " "motorb.setdirectpolarity=M0 " "motorb.setpower=M0 "
    "motorb.setreverspolarity=M0 " "motorb.setspeed=M0 " "motorb.start=M0 "
    "motorb.startpower=M0 " "motorb.startspeed=M0 " "motorbc.off=M0 "
    "motorbc.offandbrake=M0 " "motorbc.setpower=M0 " "motorbc.setspeed=M0 "
    "motorbc.start=M0 " "motorbc.startpower=M0 " "motorbc.startspeed=M0 "
    "motorbd.off=M0 " "motorbd.offandbrake=M0 " "motorbd.setpower=M0 "
    "motorbd.setspeed=M0 " "motorbd.start=M0 " "motorbd.startpower=M0 "
    "motorbd.startspeed=M0 " "motorc.getspeed=M3 " "motorc.gettacho=M3 "
    "motorc.islarge=M0 " "motorc.ismedium=M0 " "motorc.off=M0 "
    "motorc.offandbrake=M0 " "motorc.resetcount=M0 " "motorc.setdirectpolarity=M0 "
    "motorc.setpower=M0 " "motorc.setreverspolarity=M0 " "motorc.setspeed=M0 "
    "motorc.start=M0 " "motorc.startpower=M0 " "motorc.startspeed=M0 "
    "motorcd.off=M0 " "motorcd.offandbrake=M0 " "motorcd.setpower=M0 "
    "motorcd.setspeed=M0 " "motorcd.start=M0 " "motorcd.startpower=M0 "
    "motorcd.startspeed=M0 " "motord.getspeed=M3 " "motord.gettacho=M3 "
    "motord.islarge=M0 " "motord.ismedium=M0 " "motord.off=M0 "
    "motord.offandbrake=M0 " "motord.resetcount=M0 " "motord.setdirectpolarity=M0 "
    "motord.setpower=M0 " "motord.setreverspolarity=M0 " "motord.setspeed=M0 "
    "motord.start=M0 " "motord.startpower=M0 " "motord.startspeed=M0 "
    "program.argumentcount=M3 " "program.delay=M0 " "program.directory=M1 "
    "program.end=M0 " "program.getargument=M1 " "row.delete=M0 "
    "row.init=M3 " "row.read=M3 " "row.resize=M0 "
    "row.size=M3 " "row.write=M0 " "sensor.communicatei2c=M4 "
    "sensor.getmode=M3 " "sensor.getname=M1 " "sensor.gettype=M3 "
    "sensor.isbusy=M1 " "sensor.readi2cregister=M3 " "sensor.readi2cregisters=M4 "
    "sensor.readpercent=M3 " "sensor.readraw=M4 " "sensor.readrawvalue=M3 "
    "sensor.senduartdata=M0 " "sensor.setmode=M0 " "sensor.wait=M0 "
    "sensor.writei2cregister=M0 " "sensor.writei2cregisters=M0 " "sensor1.raw1=M3 "
    "sensor1.raw3=M0 " "sensor2.raw1=M3 " "sensor2.raw3=M0 "
    "sensor3.raw1=M3 " "sensor3.raw3=M0 " "sensor4.raw1=M3 "
    "sensor4.raw3=M0 " "speaker.isbusy=M1 " "speaker.note=M0 "
    "speaker.play=M0 " "speaker.stop=M0 " "speaker.tone=M0 "
    "speaker.wait=M0 " "text.append=M1 " "text.converttolowercase=M1 "
    "text.converttouppercase=M1 " "text.endswith=M1 " "text.getcharacter=M1 "
    "text.getcharactercode=M3 " "text.getindexof=M3 " "text.getlength=M3 "
    "text.getsubtext=M1 " "text.getsubtexttoend=M1 " "text.issubtext=M1 "
    "text.startswith=M1 " "thread.createmutex=M3 " "thread.lock=M0 "
    "thread.run=E0 " "thread.unlock=M0 " "thread.yield=M0 "
    "time.get1=M3 " "time.get2=M3 " "time.get3=M3 "
    "time.get4=M3 " "time.get5=M3 " "time.get6=M3 "
    "time.get7=M3 " "time.get8=M3 " "time.get9=M3 "
    "time.reset1=M0 " "time.reset2=M0 " "time.reset3=M0 "
    "time.reset4=M0 " "time.reset5=M0 " "time.reset6=M0 "
    "time.reset7=M0 " "time.reset8=M0 " "time.reset9=M0 "
    "vector.add=M4 " "vector.data=M4 " "vector.init=M4 "
    "vector.multiply=M4 " "vector.sort=M4 "
)


@fieldwise_init
struct BuiltinSig(Copyable, Movable, ImplicitlyCopyable):
    """Подпись встроенного: тип объекта и выходной тип (0 = нет записи)."""
    var obj_type: Int
    var out_type: Int


def parse_builtin_table() -> Dict[String, BuiltinSig]:
    """BUILTIN_OUTPUT -> словарь имя -> BuiltinSig."""
    var d = Dict[String, BuiltinSig]()
    var entry = String("")
    var i = 0
    var n = BUILTIN_OUTPUT.byte_length()
    while i < n:
        var ch = BUILTIN_OUTPUT[byte=i]
        if ch == " ":
            if entry != "":
                var eq = entry.find("=")
                if eq != -1:
                    var ot = String(entry[byte=eq + 1])
                    var vt = String(entry[byte=eq + 2])
                    var obj = OBJ_METHOD
                    if ot == "P":
                        obj = OBJ_PROPERTY
                    elif ot == "E":
                        obj = OBJ_EVENT
                    var out_t = VT_NON
                    if vt == "1":
                        out_t = VT_STRING
                    elif vt == "2":
                        out_t = VT_STRING_ARRAY
                    elif vt == "3":
                        out_t = VT_NUMBER
                    elif vt == "4":
                        out_t = VT_NUMBER_ARRAY
                    elif vt == "5":
                        out_t = VT_ANY
                    d[String(entry[byte=0:eq])] = BuiltinSig(obj, out_t)
                entry = String("")
        else:
            entry += ch
        i += 1
    return d^
