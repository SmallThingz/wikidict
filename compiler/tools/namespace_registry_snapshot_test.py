import unittest
import namespace_registry_snapshot as n

class NamespaceRegistryTest(unittest.TestCase):
    def api(self):
        return {'general':{'wikiid':'frwiktionary','lang':'fr'},'namespaces':{str(k):{'id':k,'name':name,'canonical':canonical,'case':'case-sensitive'} for k,name,canonical in [(0,'',''),(10,'Modèle','Template'),(14,'Catégorie','Category'),(106,'Thésaurus','Thésaurus'),(116,'Conjugaison','Conjugaison'),(118,'Racine','Racine'),(828,'Module','Module')]},'namespacealiases':[{'id':10,'alias':'M'}]}
    def inventory(self,api):
        return [{'id':v['id'],'name':v['name'],'case':v['case']} for v in api['namespaces'].values()]
    def test_french_ids_are_semantic_or_supplemental_never_english_guesses(self):
        api=self.api(); raw,roles=n.render('frwiktionary','20261001',api,self.inventory(api))
        self.assertEqual(roles['106']['role'],'thesaurus')
        self.assertEqual(roles['116']['role'],'supplemental')
        self.assertEqual(roles['118']['role'],'supplemental')
        self.assertEqual(roles['828']['role'],'compile_only')
        self.assertIn('10\tModèle\tTemplate\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\tM',raw.decode())
    def test_expected_name_change_and_dated_mismatch_fail(self):
        api=self.api();api['namespaces']['106']['name']='Other'
        with self.assertRaises(ValueError):n.render('frwiktionary','20261001',api,self.inventory(api))
        with self.assertRaises(ValueError):n.render('frwiktionary','20261001',self.api(),[{'id':10,'name':'Wrong','case':'case-sensitive'}])
    def test_unknown_subject_is_retained_and_invalid_aliases_fail(self):
        api=self.api();api['namespaces']['200']={'id':200,'name':'Nouveau','case':'first-letter'}
        _,roles=n.render('frwiktionary','20261001',api,self.inventory(api))
        self.assertEqual(roles['200']['role'],'supplemental')
        api['namespacealiases'].append({'id':999,'alias':'bad'})
        with self.assertRaises(ValueError):n.render('frwiktionary','20261001',api,self.inventory(api))
    def test_invalid_flags_and_control_characters_fail(self):
        api=self.api();api['namespaces']['10']['subpages']='yes'
        with self.assertRaises(ValueError):n.render('frwiktionary','20261001',api,self.inventory(api))
        api=self.api();api['namespacealiases'][0]['alias']='bad\tfield'
        with self.assertRaises(ValueError):n.render('frwiktionary','20261001',api,self.inventory(api))

    def test_exact_nonempty_dated_inventory_and_explicit_identity(self):
        api=self.api()
        for inventory in ([],self.inventory(api)[:-1],self.inventory(api)+[self.inventory(api)[0]]):
            with self.assertRaises(ValueError):n.render('frwiktionary','20261001',api,inventory)
        del api['general']['wikiid']
        with self.assertRaises(ValueError):n.render('frwiktionary','20261001',api,self.inventory(api))

    def test_namespace_default_model_is_optional(self):
        api=self.api();raw,_=n.render('frwiktionary','20261001',api,self.inventory(api))
        self.assertIn('828\tModule\tModule\tcase-sensitive\t0\t0\t0\t\tcompile_only',raw.decode())
    def test_id_keys_and_invalid_prefixes(self):
        api=self.api();api['namespaces']['10']['id']=11
        with self.assertRaises(ValueError):n.render('frwiktionary','20261001',api,self.inventory(api))
        api=self.api();api['namespacealiases'][0]['alias']='bad:prefix'
        with self.assertRaises(ValueError):n.render('frwiktionary','20261001',api,self.inventory(api))
