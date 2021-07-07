# DCMoto_MemMap
Outil d'analyse de traces d'execution de [DCMoto](http://dcmoto.free.fr/emulateur/index.html) par S. Devulder.

# Usage
```
	lua memmap.lua	[-reset] [-loop]
	                [-mach=(mo|to|??)]
	                [-from=XXXX] [-to=XXXX]
	                [-map[=NBCOLS]] [-hot] [-equ] 
	                [-html] [-smooth]
	                [-verbose[=N]]
	                [?|-h|--help]
```
Le programme attends que le fichier `dcmoto_trace.txt` apparaisse dans le repertoire courant. Ensuite il l'analyse, et produit un fichier `memmap.csv` contenant l'analyse de la trace. Ce fichier liste les adresses mémoires trouvées dans les trace. 

Chaque ligne est de la forme:

>```NNNN <tab> RRRR <tab> WWWW <tab> NUM <tab> ASM```

où:
- `<tab>` est une tabulation, ainsi le fichier au format CSV peut être lu et correctement affiché par un tableur, ou même un simple éditeur de texte.
- `NNNN` est une adresse mémoire en hexadécimal. 
- `RRRR` est l'adresse (hexadécimal) de la dernière instruction cpu qui a lu cette adresse. 
- `WWWW` est l'adresse de la dernière instruction cpu qui l'a modifié.
Si aucune instruction n'a lu (ou écrit à) ces adresses alors un `----` est présent.
- `NUM` contient un nombre ("-" représente un 0). Il indique le nombre de fois où le CPU a executé cet octet.
- `ASM` contient le code ASM ainsi que le nombre de cycles pour l'instruction correspondante au `NUM` précédent. Il peut aussi contenir quelques informations utiles fournies par les "equates".
	
Une zone mémoire que le cpu n'a ni lu, ni écrit, ni executé quoi que ce soit est indiquée par un message du type:

>```NUM bytes untouched.```

Cela évite d'afficher pleins de lignes totalement vide et réduit la taille du 	fichier CSV.

L'analyse se fait entre les bornes indiquées par les options `-from=XXXX` et `-to=XXXX`. Les valeurs sont en hexadécimal signé 16 bits (*truc:* utilisez -1 pour 65535). Par défaut l'analyse se fait sur les 64ko adressables par le mc6809. Plus la zone à analysée est grosses et plus les fichiers produits sont lourds.

L'option `-mach=TO` ou `-mach=MO` selectionne un type de machine. La zone analysée correspond alors à la seule RAM utilisateur du type de machine choisie. Cela réduit la taille des fichiers générés. Les "equates" sont aussi restreints aux seuls equates correspondant à la machine choisie. L'option `-mach=??` essaye de deviner le type de machine par des moyens statistiques assez fiables.


Ce fonctionnement de base de l'outil peut être étendu par quelques optons de la ligne de commande:
* __-reset__  
	Par défault l'outil cumule les valeurs des analyses précédentes. Cela permet d'amméliorer la qualité de l'analyse. Cependant si la trace présente ne correspond pas au programme à étudier il faut l'ignorer. C'est précisément ce que permet cette option. Avec elle le fichier de trace déjà présent ne sera pas lu et l'outil partira de zéro dans son analyse avant de reboucler si demandé (voir option suivante).
* __-loop__  
	Si cette option est présente, l'outil efface le fichier de trace lu et reboucle en attente d'un nouveau. Il faut alors le stopper en faisant `ctrl-c`.

Plusieurs options gouvernent le contenu du fichier produit:
* __-equ__  
	Ajoute une annotation concernant un equate thomson reconnu dans les adresses.
* __-hot__  
	Une analyse des points chauds (endroits où le cpu passe le plus de temps) est ajoutée.
* __-map__  
	Ajoute une représentation 2D de la cartographie mémoire pour avoir une vue d'ensemble bien plus compacte que la liste linéaire de base. La largeur de cette cartographie est par défauut de 128 octets. Un kilo-octet représente alors 8 lignes, et l'ensemble des 64ko recouivre 512 lignes. C'est beaucoup, mais heuresement l'outil saute par dessus 8 lignes consécutives vides pour réduire cela.
* __-map=NUM__  
	Utilise NUM colonnes dans la représentation 2D. Attention à ne pas le choisir trop petit ou trop gros pour que cela reste lisible (256 est possible si on a un grand écran). L'idée ici est d'avoir une vue synthétique.

Si l'option `-html` est présente, alors un fichier `memmap.html` est aussi produit. L'option `-smooth` utilisera alors un scrolling pour sauter d'un endroit à l'autre (ne pas l'appliquer si on a facilement le mal des transports). Le fichier HTML permet une navigation aisée via des hyperliens pour aller d'une adresse à une autre. La vue 2D utilise en outre un code couleur pour indiquer la nature de l'octet. 

Si on laisse la souris un certain temps sur un hyperlien, des infos synthétiques sont affichées sur l'adresse en question. Si l'adresse contient du code la vue assembleur est indiquée, s'il est lu ou écrit les instructions mises en jeu sont aussi affichées. 

En principe le fichier HTML est compatible tout "brouteur", y compris ceux en mode texte ou ceux fonctionnant en mode ésombre". Attention toutefois, comme il est assez gros cerains "browsers" mettent de temps à l'afficher. A l'heure actuelle il semble que ce soit Firefox qui soit le plus perfomant. Chrome mets plus de temps, mais une barre de progression est affichée durant le chargement pour patienter.

# Example

Cliquez sur [ce lien](https://htmlpreview.github.io/?https://raw.githubusercontent.com/Samuel-DEVULDER/DCMoto_MemMap/main/memmap.html) pour jouer avec une version HTML.
