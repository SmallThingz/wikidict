b = require('Module:bases')

local p = {}

-- Cherche et renvoie le nom de la langue depuis notre liste locale [[Module:langues/data]].
-- Fonction utilisable dans d’autres modules seulement
function p.get_nom(code)
    -- Pas de code langue ? Renvoie nil.
    if (code == nil) then return nil end
    
    -- Espaces avant et après enlevés
     code = mw.text.trim(code)
    
    -- Récupère la table des langues entière (en cache)
    local langues = mw.loadData('Module:langues/data')
    
    -- A-t-on la langue correspondant au code donné ?
    if (langues[code] and langues[code]['nom']) then
        -- Trouvé ! Renvoie le nom
        return langues[code]['nom']
    else
        -- Pas trouvé : on renvoie nil
        return nil
    end
end

-- Fonction pouvant remplacer les appels de type {{ {{{lang}}} }} dans les modèles
-- Cette fonction marche pour un modèle
function p.nom_langue(frame)
    local args
    if frame.args ~= nil and frame.args[1] ~= nil then
        args = frame.args
    else
        args = frame:getParent().args
    end
    local code = args[1]
    
    local langue = p.get_nom(code)
    
    if (langue == nil or langue == '') then
        return ''
    else
        return langue
    end
end

-- Fonction pour écrire le nom d'une langue dans une liste (or traductions)
-- Cette fonction marche pour un modèle {{L}}
function p.langue_pour_liste(frame)
    local args
    if frame.args ~= nil and frame.args[1] ~= nil then
        args = frame.args
    else
        args = frame:getParent().args
    end
    local code = args[1]
    
    -- Un code est-il donné?
    if code == nil or mw.text.trim(code) == '' then
        return "''Pas de code donné''" .. b.fait_categorie_contenu('Wiktionnaire:Codes langue manquants')
    end
    
    code = mw.text.trim(code)
     
    local langue = p.get_nom(code)
    
    if (langue == nil or langue == '') then
        return code .. '*' .. b.fait_categorie_contenu('Wiktionnaire:Codes langue non définis')
    else
        return b.ucfirst(langue)
    end
end

-- Cherche et renvoie le code Wikimedia du Wiktionnaire correspondant s'il existe
function p.get_lien_Wikimedia(code)
    -- Pas de code langue ? Renvoie nil.
    if (code == nil) then return nil end
    
    -- Espaces avant et après enlevés
     code = mw.text.trim(code)
    
    -- Récupère la table des langues Wikimedia (en cache)
    local langues = mw.loadData('Module:langues/data')
    
    -- A-t-on la langue correspondant au code donné ?
    if (langues[code] and langues[code]['wmlien']) then
        -- Trouvé ! Renvoie le nom
        return langues[code]['wmlien']
    else
        -- Pas trouvé : on renvoie nil
        return nil
    end
end

function p.has_portail(code)
	-- Récupère la table des langues entière (en cache)
	local langues = mw.loadData('Module:langues/data')

	if (langues[code] and langues[code]['portail']) then
		return true
	else
		return false
	end
end

return p