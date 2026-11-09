local b = {}
langfr = mw.language.new('shy')

-- Doit-on faire une élision devant ce mot ?
-- NB: cas particuliers non pris en charge (e.g. haricot)
function b.is_elidable(mot)
    mot = b.lcfirst(mot)
    if (mw.ustring.match( mot, "^h?[aáàâäeéèêëiíìîïoóòôöuúùûüǘǜ]" ) ~= nil) then
        return true
    else
        return false
    end
end

-- S'agit-il d'une locution ?
function b.is_locution(mot)
    if mot==nil then return nil end
    if (mw.ustring.find(mot, ". .") ~= nil) then
        return true
    else
        return false
    end
end

function b.page_existe(titre)
    if titre == nil then return nil end
    -- On crée un objet "mw.title" avec le titre de la page dont on cherche à vérifier l'existence
    local article = mw.title.new(titre)
    return article.exists
end

-- Renvoie le texte avec la première lettre en majuscule (si le texte est en français)
function b.ucfirst(texte)
    if (texte == nil) then return texte end
    return (mw.ustring.gsub(texte, "^([’ǂǃǀǁ]*.)", b.uc))
end
-- Renvoie le texte avec la première lettre en minuscule (si le texte est en français)
function b.lcfirst(texte)
    if (texte == nil) then return texte end
    locale = mw.language.new('fr')
    return locale:lcfirst(texte)
end
-- Renvoie le texte en majuscule (si le texte est en français)
function b.uc(texte)
    if (texte == nil) then return texte end
    locale = mw.language.new('fr')
    return locale:uc(texte)
end
-- Renvoie le texte en minuscule (si le texte est en français)
function b.lc(texte)
    if (texte == nil) then return texte end
    locale = mw.language.new('fr')
    return locale:lc(texte)
end

-- Renvoie vrai si on est dans une page de contenu (principal, annexe, thésaurus)
function b.page_de_contenu()
    local ns = mw.title.getCurrentTitle().namespace

    -- 0 = normal, 100 = Annexe, 106 = Thésaurus
    if ns == 0 or ns == 100 or ns == 106 then
        return true
    else
        return false
    end
end

-- Renvoie vrai si on est dans une page principale
function b.page_principale()
    local ns = mw.title.getCurrentTitle().namespace

    if ns == 0 then -- 0 = normal
        return true
    else
        return false
    end
end

-- Renvoie une catégorie bien formée
function b.fait_categorie(texte, clef, ecrite)
    local cat = ecrite and ':Category:' or 'Category:'
    
    if (texte ~= nil) then
        if (clef ~= nil and clef ~= '') then
            return '[[' .. cat .. texte .. '|' .. clef .. ']]'
        else
            return '[[' .. cat .. texte .. ']]'
        end
    else
        return ''
    end
end

-- Renvoie une catégorie bien formée, si elle est dans un espace principal, d’annexe ou de thésaurus
function b.fait_categorie_contenu(texte, clef, ecrite)
    if b.page_de_contenu() then
        return b.fait_categorie(texte, clef, ecrite) or ''
    else
        return ''
    end
end

-- Renvoie une catégorie bien formée, si elle est dans un espace principal
function b.fait_categorie_principale(texte, clef, ecrite)
    if b.page_principale() then
        return b.fait_categorie(texte, clef, ecrite) or ''
    else
        return ''
    end
end

-- Crée l’entête d’un tableau wiki triable (avec les titres en paramètre)
function b.tableau_entete(titres)
    local entete = '{| class="wikitable sortable"\r\n'
    entete = entete .. '|-\r\n!' .. table.concat(titres, ' !! ')
    return entete
end

-- Crée une ligne du tableau wiki
function b.tableau_ligne(elements)
    local ligne = '|-\r\n|' .. table.concat(elements, ' || ')
    return ligne
end

-- Crée la fin d'un tableau
function b.tableau_fin()
    return "|}\r\n"
end

-- Texte en exposant
function b.exposant(txt)
    return '<sup style="font-size:83%;line-height:1">'..txt..'</sup>'
end

-- balise un texte écrit en langue étrangère
function b.balise_langue(txt, code)
	return '<span lang="' .. code .. '">' .. txt .. '</span>'
end

-- Enlève les espaces de part et d'autre de tous les paramètres fournis à arg
function b.trim_parametres(args)
    if args==nil then return nil end
    
    local trim_args = {}
    for k, v in pairs(args) do
        trim_args[k] = mw.text.trim(v)
    end
    return trim_args
end

return b