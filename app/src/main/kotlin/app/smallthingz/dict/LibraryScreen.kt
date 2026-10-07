package app.smallthingz.dict

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
fun LibraryScreen(library: LibraryStore, onImport: ()->Unit) {
    var add by remember { mutableStateOf(false) }
    var address by remember { mutableStateOf("") }
    var message by remember { mutableStateOf<String?>(null) }
    var remove by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { if(library.catalog.isEmpty() && library.busy==null) library.refreshCatalogs() }
    LazyColumn(Modifier.fillMaxSize(),contentPadding=PaddingValues(12.dp),verticalArrangement=Arrangement.spacedBy(10.dp)) {
        item { Row(verticalAlignment=Alignment.CenterVertically) {
            Text("Dictionaries",Modifier.weight(1f),style=MaterialTheme.typography.headlineMedium)
            IconButton(onClick=onImport,enabled=library.busy==null) { Icon(Icons.Outlined.FolderOpen,"Import wikblb") }
            IconButton(onClick={library.refreshCatalogs()},enabled=library.busy==null) { Icon(Icons.Outlined.Refresh,"Refresh catalogues") }
        } }
        library.busy?.let { label -> item { Column { Row(verticalAlignment=Alignment.CenterVertically) { Text(label,Modifier.weight(1f),style=MaterialTheme.typography.bodySmall); IconButton(onClick={library.cancel()}){Icon(Icons.Outlined.Close,"Cancel download")} }; library.transferDetail?.let { Text(it,style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant) }; if(library.progress>0f) LinearProgressIndicator(progress={library.progress},modifier=Modifier.fillMaxWidth()) else LinearProgressIndicator(Modifier.fillMaxWidth()) } } }
        (library.error ?: message)?.let { error -> item { Text(error,color=MaterialTheme.colorScheme.error,style=MaterialTheme.typography.bodyMedium) } }
        if(library.dictionaries.isNotEmpty()) item { Text("On this device",style=MaterialTheme.typography.titleLarge) }
        items(library.dictionaries,key={it.id}) { dictionary ->
            Column {
                Row(verticalAlignment=Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) { Text(dictionary.language,style=MaterialTheme.typography.titleMedium);Text(sourceLabel(dictionary.edition),style=MaterialTheme.typography.bodySmall);Text("${dictionary.count} words · ${dictionary.bytes/1024/1024} MB",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant) }
                    IconButton(onClick={remove=dictionary.id},enabled=library.busy==null) {Icon(Icons.Outlined.DeleteOutline,"Remove ${dictionary.language}")}
                }
                androidx.compose.animation.AnimatedVisibility(remove==dictionary.id) { Row(verticalAlignment=Alignment.CenterVertically) {
                    Text("Remove download?",Modifier.weight(1f),style=MaterialTheme.typography.bodyMedium)
                    TextButton(onClick={remove=null}){Text("Keep")};TextButton(onClick={library.remove(dictionary.id);remove=null}){Text("Remove")}
                } }
            }
        }
        item { Text("Available",style=MaterialTheme.typography.titleLarge) }
        items(library.catalog,key={it.url}) { item -> Row(verticalAlignment=Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) { Text(item.label,style=MaterialTheme.typography.titleMedium);item.bytes?.let {Text("${it/1024/1024} MB",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)} }
            val edition = dictionaryEdition(java.net.URI(item.url).path.substringAfterLast('/'))
            val installed = library.dictionaries.any { it.id==if(edition.isEmpty())item.sha256 else "${item.sha256}-$edition" }
            IconButton(onClick={library.download(item)},enabled=!installed&&library.busy==null) {Icon(if(installed) Icons.Outlined.Check else Icons.Outlined.Download,if(installed)"Installed" else "Download ${item.label}")}
        } }
        item { Row(verticalAlignment=Alignment.CenterVertically) { Text("Catalogue sources",Modifier.weight(1f),style=MaterialTheme.typography.titleLarge);IconButton(onClick={add=!add}){Icon(Icons.Outlined.Add,"Add catalogue")} } }
        if(add) item { Column {
            OutlinedTextField(address,{address=it},singleLine=true,label={Text("HTTPS .list URL")},modifier=Modifier.fillMaxWidth())
            TextButton(onClick={try{library.addSource(address);address="";add=false;message=null;library.refreshCatalogs()}catch(e:Exception){message=e.message}}){Text("Add source")}
        } }
        items(library.sources,key={it}) { source -> Row(verticalAlignment=Alignment.CenterVertically) {
            Text(source,Modifier.weight(1f),style=MaterialTheme.typography.bodySmall,maxLines=3)
            IconButton(onClick={library.removeSource(source)},enabled=library.busy==null){Icon(Icons.Outlined.Close,"Remove source $source")}
        } }
    }
}
