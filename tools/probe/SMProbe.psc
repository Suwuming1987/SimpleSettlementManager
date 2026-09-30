Scriptname SMProbe

Function TestLower(string asArg)
	string s = asArg
	int i1 = s.Find("|")
	int i2 = s.GetLength()
	int i3 = s.AsInt()
	string s2 = s.Substring(0, 2)
	Debug.Trace("probe " + i1 + i2 + i3 + s2)
EndFunction

Function TestOnlyTrace(string asArg)
	Debug.Trace("probe plain " + asArg)
EndFunction
