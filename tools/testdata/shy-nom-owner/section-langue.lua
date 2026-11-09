b = require('Module:bases')
lang = require('Module:langues')
 
local p = {}

---------------------------------------------------------------------------------------------------------------------
-- SECTION DE LANGUE
 
-- Renvoie un lien vers une page représentant la langue si elle existe : portail ou article.
-- À défaut, renvoie simplement le nom de la langue donnée en entrée.
function _page_langue(langue, code)
 
    local nom_langue = b.ucfirst(langue)    -- Nom en majuscule
    local texte_nom = nom_langue            -- Texte final
 
    -- Cette langue a-t-elle un portail?
    -- Oui? Lien!
    if (lang.has_portail(code)) then
    	local nom_portail = 'Portal:' .. nom_langue
        texte_nom = '[[' .. nom_portail .. '|' .. nom_langue .. ']]'
 
    -- Non: on regarde autre chose
    -- Nota: on évite de mettre un lien vers [[conventions internationales]]
    -- puisqu'il est inapproprié (le sens de "conventions internationales" que
    -- nous utilisons est à priori non figé et n'est pas défini dans ladite page
    -- au 22/06/2015)
    elseif (langue ~= 'conventions internationales') then
        -- Le nom de cette langue a-t-il une page?
        local page_langue = mw.title.new(langue)
 
        if (page_langue.exists) then
            texte_nom = '[[' .. langue .. '|' .. nom_langue .. ']]'
        end
    end
 
    return texte_nom
end
 
-- Préparation du titre de langue :
-- récupération du nom de la langue et création du texte affiché (avec ancre, catégorie et lien)
function _fait_titre_langue(code)
 
    -- Pas de code donné ? À corriger !
    if (code == nil or mw.text.trim(code) == '') then
        local textet = {"[[Wiktionnaire:Liste des langues|Langue inconnue]]"}
        table.insert(textet, b.fait_categorie_contenu("Wiktionnaire:Sections de langue sans langue précisée"))
        return table.concat(textet)
    end
 
    code = mw.text.trim(code)
 
    -- Récupération du nom de la langue
    local langue = lang.get_nom(code)
 
    -- Création du titre à partir du nom de la langue
    local textet_titre = {}
    if langue ~= nil then
        texte_langue = _page_langue(langue, code)
        table.insert(textet_titre, texte_langue)
 
        -- Catégorie
        table.insert(textet_titre, b.fait_categorie_contenu(langue))
 
    -- Si le code langue ne correspond à aucune langue définie
    else
        table.insert(textet_titre, b.ucfirst(code))
        table.insert(textet_titre, "[[Wiktionnaire:Liste des langues|<span title=\"code langue inconnu\">*</span>]]")
        table.insert(textet_titre, b.fait_categorie_contenu('Wiktionnaire:Sections de langue avec code inconnu'))
    end
 
    return '<span class="sectionlangue" id="' .. code .. '">' .. table.concat(textet_titre) .. '</span>'
end

-- LANGUE : FONCTION POUR MODÈLE
-- Création d'un titre de section de langue
function p.section_langue(frame)
    -- Récupération des variables nécessaires à la création du titre
    local args = frame:getParent().args
    return p.section_langue_args(args)
end
    
function p.section_langue_args(args)
    local code_langue  = args[1]
    local rare

    if (b.page_de_contenu() == true) then
     rare = p.get_lettres_rares(code_langue)
    end
    if (rare == nil) then rare = '' end
    return _fait_titre_langue(code_langue) .. rare
end

function p.get_lettres_rares(code)
    if (code == nil) then return nil end
 
    -- Espaces avant et après enlevées
     code = mw.text.trim(tostring(code))
 
    -- Récupère la table des langues Wikimedia (en cache)
    local langues = mw.loadData('Module:langues/lettres_rares')
    if (langues == nil) then return nil end
    if (langues[code] == nil) then return nil end
    if (langues[code]['rare'] == nil) then return nil end
 
    -- Catégories si lettres rares
    local cat = ""
    local l = 0
    titre = mw.title.getCurrentTitle().text
    for i = 1, string.len(titre) do
	l = mw.ustring.find(mw.ustring.sub(titre, i, i), tostring(langues[code]['rare']))
	if l ~= nil then
	    cat = cat .. "[[Taggayt:" .. b.lc(mw.ustring.sub(titre, i, i)) .. ' s ' .. lang.get_nom(code) .. "]]"
	end
    end
    return cat
 
end

return p