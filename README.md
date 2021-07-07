# DCMoto_MemMap
This is an analyzer of [DCMoto](http://dcmoto.free.fr/emulateur/index.html) execution traces by S. Devulder.

# Usage
Usage:
```
    lua.exe memmap.lua [-reset] [-loop]
                       [-mach=(mo|to|??)]
                       [-from=XXXX] [-to=XXXX]
                       [-map[=NBCOLS]] [-hot] [-equ] 
                       [-html] [-smooth]
                       [-verbose[=N]]
                       [?|-h|--help]
````
Le programme attends que le fichier dcmoto_trace.txt apparaisse dans
le repertoire courant. Ensuite il l'analyse, et produit un fichier
"memmap.csv" contenant l'analyse de la trace. Si l'option '-html' est
présente, alors un fichier "memmap.html" est aussi produit. L'option
"-smooth" utilisera alors un scrolling pour sauter d'un endroit à 
l'autre.

Si l'optrion '-hot' est présente, alors les points chauds du code
sont inclus.

L'option '-equ' ajoute une annotation concernant un equate thomson
reconnu dans les adresses.

Les fichiers résultat affichent les adresses contenues entre les
valeurs indiquées par les options '-from=XXXX' et '-to=XXXX'. Les
valeurs sont en hexadécimal. Par défaut l'analyse se fait sur les 64ko
adressables.

L'option '-mach=TO' ou '-mach=MO' selectionne un type de machine. La
zone analysée correspond alors à la seule RAM utilisateur du type de
machine choisie. Les "equates" sont aussi restreints aux seuls equates
correspondant à la machine choisie. L'option '-mach=??' essaye de 
deviner le type de machine.

Par défault l'outil cumule les valeurs des analyses précédentes, mais
si l'option '-reset' est présente, il ignore les analyses précédentes
et repart de zéro.

Si l'option '-loop' est présente, le programme efface la trace et
reboucle en attente d'une nouvelle trace.

L'option '-verbose' ou '-verbose=N' affiche des détails supplémentaires.

Le fichier memmap.csv liste les adresses mémoires trouvées dans les
trace. Chaque ligne est de la forme:
```
    NNNN <tab> RRRR <tab> WWWWW <tab> NUM <tab> ASM
```
<tab> est une tabulation, ainsi le fichier au format CSV peut être
lu et correctement affiché par un tableur.

NNNN est une adresse mémoire en hexadécimal. RRRR est l'adresse
(hexadécimal) de la dernière instruction cpu qui a lu cette adresse.
WWWW est l'adresse de la dernière instruction cpu qui l'a modifié.
Si aucune instruction n'a lu (ou écrit à) cette adresse alors un "----"
est présent.

NUM peut être vide "-" ou un nombre décimal. Le "-" indique que l'adresse
n'a jammais été executée. Un nombre décimal indique que cette ligne
fait parti d'une instruction cpu qui a été executée NUM fois. Enfin
ASM indique l'instruction ASM décodeée à cette adresse (et les suivantes
si l'adresse est sur plusieurs octets).

Une zone mémoire où le cpu n'a ni lu, ni écrit quelque chose est
indiquée par un message du type:
```
     NUM bytes untouched.
```

# Example
Click [this link](https://htmlpreview.github.io/?https://raw.githubusercontent.com/Samuel-DEVULDER/DCMoto_MemMap/main/memmap.html) to view an example. 
**Beware** this might take quite some time.