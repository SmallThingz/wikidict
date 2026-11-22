package app.smallthingz.dict

import android.text.format.Formatter
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.clickable
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

@Composable
fun LibraryScreen(library: LibraryStore, autoRefresh: Boolean = true,
    onImportEdition: (() -> Unit)? = null, onSelectEmpty: (EmptyEditionInfo) -> Unit = {}, onImport: ()->Unit) {
    val context = LocalContext.current
    var add by remember { mutableStateOf(false) }
    var importMenu by remember { mutableStateOf(false) }
    var removeEmpty by remember { mutableStateOf<String?>(null) }
    var address by remember { mutableStateOf("") }
    var message by remember { mutableStateOf<String?>(null) }
    var remove by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        if(autoRefresh && library.sources.isNotEmpty() && library.catalog.isEmpty() && library.busy==null && library.error==null)
            library.refreshCatalogs()
    }
    LazyColumn(Modifier.fillMaxSize(),contentPadding=PaddingValues(12.dp),verticalArrangement=Arrangement.spacedBy(10.dp)) {
        item { Row(verticalAlignment=Alignment.CenterVertically) {
            Text("Dictionaries",Modifier.weight(1f),style=MaterialTheme.typography.headlineMedium)
            Box {
                IconButton(onClick={ if (onImportEdition == null) onImport() else importMenu=true },enabled=library.busy==null) {
                    Icon(Icons.Outlined.FolderOpen,if (onImportEdition == null) "Import wikblb" else "Import")
                }
                DropdownMenu(expanded=importMenu,onDismissRequest={importMenu=false}) {
                    DropdownMenuItem(text={Text("Dictionary file")},onClick={importMenu=false;onImport()})
                    DropdownMenuItem(text={Column {
                        Text("Completed-empty edition folder")
                        Text("Newest dated release, e.g. inside aawiktionary",style=MaterialTheme.typography.bodySmall)
                    }},onClick={importMenu=false;onImportEdition?.invoke()})
                }
            }
            IconButton(onClick={library.refreshCatalogs()},enabled=library.sources.isNotEmpty()&&library.busy==null) { Icon(Icons.Outlined.Refresh,"Refresh catalogues") }
        } }
        (library.busy ?: if (library.hasRetainedDownload) "Download needs attention" else null)?.let { label ->
            item { Column {
                Row(verticalAlignment=Alignment.CenterVertically) {
                    Text(label,Modifier.weight(1f),style=MaterialTheme.typography.bodySmall)
                    IconButton(onClick={library.cancel()}) { Icon(Icons.Outlined.Close,"Cancel operation") }
                }
                library.transferDetail?.let { Text(it,style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant) }
                if (library.busy != null) {
                    if (library.progress>0f) LinearProgressIndicator(progress={library.progress},modifier=Modifier.fillMaxWidth())
                    else LinearProgressIndicator(Modifier.fillMaxWidth())
                }
            } }
        }
        library.initializationError?.let { error -> item { Text(error,color=MaterialTheme.colorScheme.error,style=MaterialTheme.typography.bodyMedium) } }
        library.error?.let { error -> item { Text(error,color=MaterialTheme.colorScheme.error,style=MaterialTheme.typography.bodyMedium) } }
        if(library.dictionaries.isNotEmpty() || library.emptyEditions.isNotEmpty()) item { Text("On this device",style=MaterialTheme.typography.titleLarge) }
        items(library.dictionaries,key={it.id}) { dictionary ->
            Column {
                Row(verticalAlignment=Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) { Text(dictionary.language,style=MaterialTheme.typography.titleMedium);Text(sourceLabel(dictionary.edition),style=MaterialTheme.typography.bodySmall);Text("${dictionary.count} ${if (dictionary.count == 1) "entry" else "entries"} · ${Formatter.formatShortFileSize(context, dictionary.bytes)}",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant) }
                    IconButton(onClick={remove=dictionary.id},enabled=library.busy==null) {Icon(Icons.Outlined.DeleteOutline,"Remove ${dictionary.language}")}
                }
                androidx.compose.animation.AnimatedVisibility(remove==dictionary.id) { Row(verticalAlignment=Alignment.CenterVertically) {
                    Text("Remove download?",Modifier.weight(1f),style=MaterialTheme.typography.bodyMedium)
                    TextButton(onClick={remove=null}){Text("Keep")};TextButton(onClick={library.remove(dictionary.id);remove=null}){Text("Remove")}
                } }
            }
        }
        items(library.emptyEditions,key={"empty:${it.edition}"}) { edition ->
            Column {
                Row(verticalAlignment=Alignment.CenterVertically) {
                    Column(Modifier.weight(1f).clickable { onSelectEmpty(edition) }.padding(vertical=8.dp)) {
                        Text(sourceLabel(edition.edition),style=MaterialTheme.typography.titleMedium)
                        Text("Completed release · No published dictionaries",style=MaterialTheme.typography.bodyMedium)
                        Text("${edition.sourcePages} source pages processed",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    IconButton(onClick={removeEmpty=edition.edition},enabled=library.busy==null) {
                        Icon(Icons.Outlined.DeleteOutline,"Remove summary for ${sourceLabel(edition.edition)}")
                    }
                }
                androidx.compose.animation.AnimatedVisibility(removeEmpty==edition.edition) { Row(verticalAlignment=Alignment.CenterVertically) {
                    Text("Remove saved summary? The source folder is kept.",Modifier.weight(1f),style=MaterialTheme.typography.bodyMedium)
                    TextButton(onClick={removeEmpty=null}){Text("Keep")}
                    TextButton(onClick={library.removeEmptyEdition(edition.edition);removeEmpty=null}){Text("Remove")}
                } }
            }
        }
        item { Text("Available",style=MaterialTheme.typography.titleLarge) }
        if (library.catalog.isEmpty() && library.busy == null) item {
            Text(if (onImportEdition == null) "No downloads listed. Add a catalogue or import a file." else "No downloads listed. Add a catalogue or import a dictionary file or completed-empty edition.",style=MaterialTheme.typography.bodyMedium,color=MaterialTheme.colorScheme.onSurfaceVariant)
        }
        items(library.catalog,key={it.url}) { item -> Row(verticalAlignment=Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) { Text(item.label,style=MaterialTheme.typography.titleMedium);item.bytes?.let {Text(Formatter.formatShortFileSize(context, it),style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)} }
            val edition = dictionaryEdition(java.net.URI(item.url).path.substringAfterLast('/'))
            val installed = library.dictionaries.any { it.id==if(edition.isEmpty())item.sha256 else "${item.sha256}-$edition" }
            IconButton(onClick={library.download(item)},enabled=!installed&&library.busy==null) {Icon(if(installed) Icons.Outlined.Check else Icons.Outlined.Download,if(installed)"Installed" else "Download ${item.label}")}
        } }
        item { Row(verticalAlignment=Alignment.CenterVertically) { Text("Catalogue sources",Modifier.weight(1f),style=MaterialTheme.typography.titleLarge);IconButton(onClick={add=!add;message=null}){Icon(Icons.Outlined.Add,"Add catalogue")} } }
        if(add) item { Column {
            OutlinedTextField(address,{address=it;message=null},singleLine=true,label={Text("HTTPS .list URL")},
                isError=message!=null,supportingText=if(message!=null) { { Text(message.orEmpty()) } } else null,
                modifier=Modifier.fillMaxWidth())
            TextButton(onClick={try{library.addSource(address);address="";add=false;message=null;library.refreshCatalogs()}catch(e:Exception){message=e.message}}){Text("Add source")}
        } }
        items(library.sources,key={it}) { source -> Row(verticalAlignment=Alignment.CenterVertically) {
            Text(source,Modifier.weight(1f),style=MaterialTheme.typography.bodySmall,maxLines=3)
            IconButton(onClick={library.removeSource(source)},enabled=library.busy==null){Icon(Icons.Outlined.Close,"Remove source $source")}
        } }
    }
}
