-- Rückgabe einer Tabelle mit arabischen Ziffern, welche die Auffindung von Artikeln der als arabische 
-- Ziffern angegebenen Zahlen ermöglicht und über einen Link zugänglich macht

local export = {}
local spraaken = mw.loadData("Module:languages")

function export.zahlenlinktabelle(frame)
	-- als Argument angegebnenen Sprachcode ermitteln
	local args = frame.args
	local spraakcode = args[1] or error("Spraak-Code nich angeven!")
	-- Gibt es den übergebenen Sprachcode überhaupt ?
	local spraakinfo = spraaken[spraakcode] or error("Spraak-Code \"" .. spraakcode .. "\" givt et nich!")

	-- Wenn ja, Spraaknamen vun Modul languages holen
	local spraaknaam = spraakinfo["name"]
	
	
	-- Datenmodul mit den Zahlworten aus der jeweiligen Sprache laden
	local tallwoortlist = mw.loadData("Modul:nds Kardinaltalen") or error("Et gevt keen Datenmodul för \"" .. spraakcode .. "\".")

    -- Hole die Liste mit allen Zahlworten in die lokale Tabelle Woorts
    local woorts = {}
     for woort, _ in pairs(tallwoortlist) do
        table.insert(woorts, woort)
    end
    local zaehler = 1
    -- 10 pro Zeile, 12 Zeilen
    ri = 1
    while (ri <= 12) do
	    zi = 1
    	while (zi <=10) do
    		......
    		zaehler = zähler + 1
    		zi = zi +1
    	end
    	ri = ri + 1
    end

	return
		"<div class=\"NavFrame\" style=\"width: 25em\">\n" ..
    	"<div class=\"NavHead\" style=\"text-align:left\">Kardinaltalen in [[Wiktionary:Över " + spraaknaam + "/Numeralen{{!}}" + spraaknaam + "]] finnen</div>\n" ..
    	"<div class=\"NavContent\">\n" ..
    	"{| class=\"wikitable\"\n" ..
    	"|-" .. table.concat(rows, "\n|-") .. "\n|}</div></div>"
end