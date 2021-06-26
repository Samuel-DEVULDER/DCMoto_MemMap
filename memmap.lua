------------------------------------------------------------------------------
-- memmap.lua : Outil d'analye de traces DCMoto par S. Devulder.
--
-- Usage:
--     lua.exe memmap.lua [-reset] [-loop] [-from=XXXX] [-to=XXXX]
--                        [-html [-map[=NBCOLS]]] 
--
-- Le programme attends que le fichier dcmoto_trace.txt apparaisse dans
-- le repertoire courant. Ensuite il l'analyse, et produit un fichier
-- memmap.csv contenant l'analyse de la trace et un fichier memmap.html
-- si l'option '-html' est présente. Le fichier html affichera une image
-- de l'organisation mémoire au début si l'option '-map' est présente
--
-- Les fichiers résultat affichent les adresses contenues entre les
-- valeurs indiquées par les options '-from=XXXX' et '-to=XXXX'. Les
-- valeurs sont en hexadécimal. Par défaut l'analyse se fait sur les 64ko
-- adressables. 
--
-- Par défault l'outil cumule les valeurs des analyses précédentes, mais
-- si l'option '-reset' est présente, il ignore les analyses précédentes
-- et repart de zéro.
--
-- Si l'option '-loop' est présente, le programme efface la trace et
-- reboucle en attente d'une nouvelle trace.
--
-- Le fichier memmap.csv liste les adresses mémoires trouvées dans les
-- trace. Chaque ligne est de la forme:
--
--      NNNN <tab> RRRR <tab> WWWWW <tab> NUM <tab> ASM
--
-- <tab> est une tabulation, ainsi le fichier au format CSV peut être
-- lu et correctement affiché par un tableur.
--
-- NNNN est une adresse mémoire en hexadécimal. RRRR est l'adresse
-- (hexadécimal) de la dernière instruction cpu qui a lu cette adresse.
-- WWWW est l'adresse de la dernière instruction cpu qui l'a modifié.
-- Si aucune instruction n'a lu (ou écrit) cette adresse alors un "----"
-- est présent.
--
-- NUM peut être "-" ou un nombre décimal. Le "-" indique que l'adresse
-- n'a jammais été executée. Un nombre décimal indique que cette ligne
-- fait parti d'une instruction cpu qui a été executée NUM fois. Enfin
-- ASM indique l'instruction ASM décodeée à cette adresse (et les suivantes
-- si l'adresse est sur plusieurs octets).
--
-- Une zone mémoire où le cpu n'a ni lu, ni écrit quelque chose est
-- indiquée par un message du type:
--
--      NUM bytes untouched.
--
------------------------------------------------------------------------------


local NOADDR = '----'              -- marqueur d'absence
local TRACE  = 'dcmoto_trace.txt'  -- fichier trace
local RESULT = 'memmap'            -- racine des fichiers résultats
local HTML   = false               -- produit une analyse html?
local LOOP   = false               -- reboucle ?
local RESET  = false               -- ignore les analyses précédentes ?
local MAP    = false               -- ajoute une version graphique de la map
local MAPCOL = 128                 -- nb de colonnes de la table map
local MINADR = 0x0000              -- adresse de départ
local MAXADR = 0xFFFF              -- adresse de fin

-- local BRAKET = {' .oO(',')'}
-- local BRAKET = {' (',')'}
-- local BRAKET = {'<<',''}
local BRAKET = {' <-',''}

for i,v in ipairs(arg) do local t
    if v=='-loop'  then LOOP  = true end
    if v=='-html'  then HTML  = true end
    if v=='-reset' then RESET = true end
    if v=='-map'   then MAP   = true end
    t=v:match('%-from=(%x+)') if t then MINADR = tonumber(t,16) end
    t=v:match('%-to=(%x+)')   if t then MAXADR = tonumber(t,16) end
    t=v:match('%-map=(%d+)')  if t then MAP,MAPCOL = true,tonumber(t) end
end

------------------------------------------------------------------------------

local unpack = unpack or table.unpack

-- formatage à la C
local function sprintf(...)
    return string.format(...)
end

-- affiche un truc sur la sortie d'erreur (pas de buffferisation)
local function out(...)
    io.stderr:write(sprintf(...))
    io.stderr:flush()
end

-- set
local function set(list)
    local r = {}
    for _,x in ipairs(list) do r[x] = true end
    return r
end

-- hexa 16 bits
local function hex(n)
    return sprintf('%04X', n)
end

-- addition 16 bits
local function add16(a,b)
    return (a+b+65536)%65536
end

-- efface les blancs en début et fin de chaine
local function trim(txt)
    return txt:match('^%s*(.*%S)')
end

-- memoization
local memoize = {
    size  = 0,
    cache = {},
    make = function(self, fcn)
        -- do return fcn end
        return function(...)
            local args = {...}
            local k = ''
            for i,v in ipairs(args) do k = k .. ':' .. tostring(v) end
            local function set(...)
                local v = {...}
                if self.size >= 65536 then self.size, self.cache = 0, {} end
                self.size, self.cache[k] = self.size + 1, v
                return v
            end
            return unpack(self.cache[k] or set(fcn(...)))
        end
    end
}

------------------------------------------------------------------------------
-- Quelques adresses bien connues
------------------------------------------------------------------------------

local EQUATES = {
    _mach = '',
    m = function(self,mach)
        self._mach = mach or ''
        return self
    end,
    _page = '',
    p = function(self,page)
        self._page = page or ''
        return self
    end,
    d = function(self,addr,name, ...) 
        if addr then
            self[self._page .. addr] = self._mach .. name
            self:d(...)
        end
        return self
    end,
    t = function(self,addr)
        return self[addr or ''] and BRAKET[1]..self[addr]..BRAKET[2] or ''
    end
} EQUATES
:d('FFFE','VEC.RESET',
   'FFFC','VEC.NMI',
   'FFFA','VEC.SWI',
   'FFF8','VEC.IRQ',
   'FFF6','VEC.FIRQ',
   'FFF4','VEC.SWI2',
   'FFF2','VEC.SWI3',
   'FFF0','VEC.UNK')
:m('TO.')
-- TO8 monitor
:d('EC0C','EXTRA',
   'EC09','PEIN',
   'EC06','GEPE',
   'EC03','COMS',
   'EC00','SETP',
   nil)
-- TOx monitor
:d('E833','CHPL',
   'E830','KBIN',
   'E82D','MENU',
   'E82A','DKCO',
   'E827','JOYS',
   'E824','GETS',
   'E821','GETP',
   'E81E','NOTE',
   'E81B','LPIN',
   'E818','GETL',
   'E815','K7CO',
   'E812','RSCO',
   'E80F','PLOT',
   'E80C','DRAW',
   'E809','KTST',
   'E806','GETC',
   'E803','PUTC')
-- PAGE 0
-- Redir moniteur TO
:d('6000','*GETLP',
   '6002','*LPIN',
   '6004','*GETP',
   '6006','*GACH',
   '6008','*PUTC',
   '600A','*GETC',
   '600C','*DRAW',
   '600E','*PLOT',
   '6010','*RSCONT',
   '6012','*GETP',
   '6014','*GETS',
   nil)
-- Registres moniteur
:d('6016','SAVPAL',
   '6019','STATUS',
   '601A','TABPT',
   '601B','RANG',
   '601C','TOPTAB',
   '601D','TOPRAN',
   '601E','BOTTAB',
   '601F','BOTRAN',
   '6020','COLN',
   '6021','IRQPT',
   '6023','FIRQPT',
   '6025','COPBUF',
   '6027','TIMEPT',
   '6029','K7OPC',
   '602A','K7STA',
   '602B','RSOPC',
   '602C','RSSTA',
   '602D','USERAF',
   '602F','SWI1',
   '6031','TEMPO',
   '6033','DUREE',
   '6035','TIMBRE',
   '6036','OCTAVE',
   '6038','FORME',
   '6039','ATRANG',
   '603A','ATSCR',
   '603B','COLOUR',
   '603C','TELETL',
   '603D','PLOTX',
   '603F','PLOTY',
   '6041','CHDRAW',
   '6042','CURSFL',
   '6043','COPCHR',
   '6044','BAUDS',
   '6046','NOMBRE',
   '6047','GRCODE',
   '6048','DKOPC',
   '6049','DKDRV',
   '604A','DKTRK',
   '604C','DKSEC',
   '604D','DKNUM',
   '604E','DKSTA',
   '604F','DKBUF',
   '6051','TRAK0',
   '6053','TRAK1',
   '6055','TEMP1',
   '6057','TEMP2',
   '6058','ROTAT',
   '6059','SEQCE',
   '605A','SCRPT',
   '605C','SAVCOL',
   '605D','ASCII',
   '605E','RDCLV',
   '605F','SCRMOD',
   '6060','STADR',
   '6062','ENDDR',
   '6064','TCRSAV',
   '6065','TCTSAV',
   '6067','WRCLV',
   '6068','SAVATR',
   '606A','US1',
   '606B','COMPT',
   '606C','TEMP',
   '606E','SAVEST',
   '6070','ACCENT',
   '6071','SS2GET',
   '6072','SS3GET',
   '6073','BUZZ',
   '6074','CONFIG',
   '6065','EFCMPT',
   '6076','BLOCZ',
   '6078','SCROLS',
   '6079','CUFCLV',
   '607B','SIZCLV',
   '607C','ACCES',
   '607D','PERIPH',
   '607E','PERIF1',
   '607F','RUNFLG',
   '6080','DKFLG',
   '6081','CPYE7E7', --'IDSAUT',
   '6086','CURSFLG',
   '6087','TEMP2',
   '6088','RESETP',
   '608B','STACK',
   '60CD','PTCLAV',
   '60CF','PTGENE',
   '60D1','APPLIC',
   '60D2','DECALG',
   '60D3','LPBUFF',
   '60FE','TSTRST',
   nil)
-- registres minidos
-- :m('TO.dos.')
:d('60E5','DKERR',
   '60E7','DKNAM',
   '60E9','DKCAT',
   '60EB','DKTYP',
   '60EC','DKFLG',
   '60ED','DKFAT',
   '60F0','DKMOD',
   '60F3','DKFIN',
   '60F5','DKSCT',
   '60F6','BKBLK',
   '60F7','DKTDS',
   '60F9','DKIFA',
   '60FA','DKPSB',
   '60FB','DKPBC',
   nil) 
-- minidos
:d('E004','DKCON',
   'E007','DKBOOT',
   'E00A','DKFMT',
   'E00D','LECFA',
   'E010','RECFI',
   'E013','RECUP',
   'E016','ECRSE',
   'E019','ALLOD',
   'E01B','ALLOB',
   'E01F','MAJCL',
   'E022','FINTR',
   nil)
-- 6846 système
-- :m('TO.mc6846.')
:d('E7C0','CSR',
   -- port C
   'E7C1','CRC',
   'E7C2','DDRC',
   'E7C3','PRC',
   -- timer
   'E7C5','TCR',
   'E7C6','TMSB',
   'E7C7','TLSB',
   nil)
-- 6021 système
-- :m('TO.pia6021.')
:d('E7C8','PRA',
   'E7C9','PRB',
   'E7CA','CRA',
   'E7CB','CRB',
   nil)
-- 6021 musique & jeux
:d('E7CC','PRA1',
   'E7CD','PRA2',
   'E7CE','CRA1',
   'E7CF','CRA2',
   nil)
-- i/o palette
-- :m('TO.IGV9369.')
:d('E7DA','PALDAT',
   'E7DB','PALDAT/IDX',
   nil)
-- gate array affichage
-- :m('TO.FGG06')
:d('E7DC','LGAMOD',
   'E7DD','LGATOU',
   nil)
-- 6850 système (clavier TO9)
-- :m('TO.mc6850')
:d('E7DE','SCR/SSDR',
   'E7DF','STDR/SRDR',
   nil)
-- gate array systeme (crayon optique)
-- :m('TO.GateArray')
:d('E7E4','LGASYS2',
   'E7E5','LGARAM',
   'E7E6','LGAROM',
   'E7E7','LGASYS1',
   nil)
for i=0,math.floor(8192/40) do 
    EQUATES:m('TO.'):d(hex(0x4000+i*40),sprintf('VRAM+40*%d',i))
    -- EQUATES:m('MO.').d(hex(0x0000+i*40),sprintf('VLIN.%03d',i))
end
   
------------------------------------------------------------------------------
-- différent formateurs de résultat
------------------------------------------------------------------------------

-- Writer Parallèle
local function newParallelWriter(...)
    return {
        writers = {...},
        close = function(self)
            for _,w in ipairs(self.writers) do w:close() end
        end,
        header = function(self,...)
            for _,w in ipairs(self.writers) do w:header(...) end
        end,
        row = function(self,...)
            for _,w in ipairs(self.writers) do w:row(...) end
        end
    }
end

-- Writer TSV (CSV avec des TAB(ulations))
local function newTSVWriter(file, tablen)
    tablen = tablen or 8
    local function align(n)
        return tablen*math.floor((n + tablen -1)/tablen)
    end
    return {
        file=file or {write=function() end, close=function() end},
        close = function(self) 
            self.file:write(self.hsep..'\n')
            self.file:write("End of file\n")
            self.file:close() 
        end,
        header = function(self, columns)
            self.ncols = #columns
            self.align = {}
            self.clen = {}
            self.hsep = ''
            cols = {}
            for i,n in ipairs(columns) do
                local tag = n:match('^([<=>])')
                self.align[i], cols[i], self.clen[i] = tag or '<', tag and n:sub(2) or n, 0
            end
            if self.ncols>0 then
                self:row(cols)
                local l=0 for i=1,self.ncols do l = l + self.clen[i] end
                self.hsep = string.rep('=', l)
                self.file:write(self.hsep .. '\n')
            end
            return self
        end,
        row = function(self, cels)
            local t = ''
            for i,n in ipairs(cels) do
                t = t .. '\t'
                if type(n)=='table' then n = sprintf(unpack(n)) else n = tostring(n) end
                if n:len()>self.clen[i] then self.clen[i] = align(n:len()) end
                if self.align[i]=='>' then 
                    t = t .. string.rep(' ', self.clen[i] - n:len() - 1) .. n
                elseif self.align[i]=='=' then
                    t = t .. string.rep(' ',math.floor((self.clen[i] - n:len())/2)) .. n
                else
                    t = t .. n
                end
            end
            self.file:write((t~='' and t:sub(2) or t)..'\n')
            return self
        end
    }
end

-- Writer HTML (quelle horreur!)
local function newHtmlWriter(file, mem)
    -- evite les fichier nil
    file=file or {write=function() end, close=function() end}
    -- aide pour imprimer
    local function w(...)
        for _,s in ipairs{...} do
            if type(s)=='table' then s = sprintf(unpack(s)) end
            file:write(tostring(s))
        end
    end
    -- échappement html
    local function esc(txt)
        return txt
        -- :gsub("<<","&laquo;")
        :gsub('['..[['"<>&]]..']', {["'"] = "&#39",['"'] = "&quot;",["<"]="&lt;",[">"]="&gt;",["&"]="&amp;"})
        :gsub("<%-", "&larr;")
        :gsub(' ','&nbsp;')
    end
    -- récup des adresses utiles
    local valid = {} for i=MINADR,MAXADR do valid[hex(i)] = true end
    local rev   = {}
    for i=MAXADR,MINADR,-1 do 
        local m = mem[i] 
        i = hex(i)
        if m and m.r~=NOADDR and valid[m.r] then rev[m.r] = i end
        if m and m.w~=NOADDR and valid[m.w] then rev[m.w] = i end
    end
    -- descrit le contenu d'une adresse
    local function describe(addr, opt_asm, opt_asm_addr)
        local function code(where)
            if where~=NOADDR then
                local i = tonumber(where,16)
                local m = mem[i]
                return m and m.asm and '\n' .. m.asm .. ' (from $' .. where .. ')' or ''
            else
                return ''
            end
        end         
        local m = mem[tonumber(addr,16)]
        if m then
            opt_asm      = m.x>0 and (m.asm or opt_asm)
            opt_asm_addr = m.x>0 and (m.asm and addr or opt_asm_addr)
            local RWX    = (m.x==0      and '-' or 'X')..
                           (m.r==NOADDR and '-' or 'R')..
                           (m.w==NOADDR and '-' or 'W')
            --
            local anchor = addr
            if opt_asm_addr and (RWX=='X--' or (RWX=='XR-' and m.asm)) then anchor = opt_asm_addr 
            elseif RWX=='-RW' and m.r==m.w then anchor = m.r 
            elseif RWX=='-R-'              then anchor = m.r
            elseif RWX=='--W'              then anchor = m.w end
            --
            local equate = EQUATES:t(addr)
            local equate_ptn = equate:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]','%%%1')
            local title  = '$' .. addr .. equate .. ' : ' .. RWX ..
                           (opt_asm and '\n' .. opt_asm:gsub(equate_ptn,'') or '') ..
                           code(m.r):gsub(equate_ptn,'')
            if m.r~=m.w then title = title .. code(m.w):gsub(equate_ptn,'') end

            return title, RWX, anchor
        else
            return '$' .. addr  .. EQUATES:t(addr) .. ' : untouched', '---', addr
        end
    end
    -- affiche le code html pour un hyperlien sur "addr" avec le texte
    -- "txt" (le tout pour l'adresse "from")
    local function ahref(from, addr, txt)
        local title, RWX, anchor = describe(addr)
        if from == anchor then anchor = addr end -- no loop back
        return '<a href="#' .. anchor .. '" title="' .. esc(title) .. '">' .. esc(txt) .. '</a>'
    end
    
    
    local function memmap(mem)
        -- encodage des couleurs de cases
        local color = {
            ['---'] = 7,
            ['--W'] = 1,
            ['-R-'] = 2,
            ['-RW'] = 3,
            ['X--'] = 4,
            ['X-W'] = 5,
            ['XR-'] = 6,
            ['XRW'] = 0,
        }

        -- affine le min/max pour réduire la taille de la carte
        local min,max = MINADR,MAXADR
        for i=min,MAXADR    do if mem[i] then min=i break end end
        for i=MAXADR,min,-1 do if mem[i] then max=i break end end
        
        w('  <h1>Memory map between $', hex(min), ' and $', hex(max),'</h1>\n')
        w('  <table class="mm">\n')
        
        local last_asm, last_asm_addr ='',''
        for j=math.floor(min/MAPCOL),math.floor(max/MAPCOL) do
            w('    <tr>')
            for i=0,MAPCOL-1 do 
              local m,a = mem[MAPCOL*j+i],hex(MAPCOL*j+i)
              if m then
                  local title, RWX, anchor = describe(a, last_asm, last_asm_addr) 
                  if m.asm then last_asm,last_asm_addr = m.asm, a end
                  w('<td', ' class="c', color[RWX],'"', ' title="',esc(title), '">',
                    '<a href="#',anchor,'"></a>',
                    '<noscript>#</noscript>',
                    '</td>')
              else
                w('<td class="c7" title="$',a,esc(EQUATES:t(a)),' : ---"><noscript>#</noscript></td>')
              end
            end
            w('</tr>\n')
        end
        w('  </table>\n')
    end
    return {
        file=file,
        close = function(self) 
            local f = self.file
            w('</table>\n',
              '<div><p></p></div>\n',
              '<a href="#TOP" id="BOTTOM">&uarr;&uarr;goto top&uarr;&uarr;</a>\n',
              '<h1>End of analysis</h1>\n')
            if MAP then 
                w('</div>\n',
                  -- '<script>document.getElementById("progress").innerHTML  = "xxx"</script>\n',
                  '<div id="memmap">\n')
                memmap(mem) 
                w('</div>')
            end
            w('<script>',
              'window.addEventListener("load", hideLoading);',
              '</script>\n')
            w('</body></html>\n')
            w()
            f:close() 
        end,
        _row = function(self, tag, columns)
            local t, cols = '', {' '}
            for i,n in ipairs(columns) do 
                cols[i] = type(n)=='table' and sprintf(unpack(n)) or tostring(n)
            end
            local last = #cols
            if last>1 and cols[1]:match("^%x%x%x%x$") then t = t .. ' id="'..cols[1]..'"' end t = t .. '>'
            for i,n in ipairs(cols) do 
                t = t .. '<' .. tag .. 
                    (i==last and i~=self.ncols and ' colspan="'..(self.ncols - i + 1)..'"' or '') ..
                    '>'
                if i==1 then
                    t = t .. esc(n)
                elseif i==2 or i==3 then
                    t = t .. (valid[n] and ahref(cols[1], n,n) or esc(n))
                elseif i==4 then 
                    t = t .. esc(n)
                elseif i==5 then
                    local back = rev[cols[1]]
                    if back then
                        local before,arg,after = n:match('^(%S+%s+%S+%s+[%[<]?%$?)([%w_,]+)(.*)$')
                        if not arg then before,arg,after = n:match('^(%S+%s+)([%w_,]+)(.+)$') end
                        if not arg then before,arg,after = '',n,'' end
                        -- if arg:sub(1,1)=='$' then before,arg = before..'$',arg:sub(2) end
                        n = esc(before) .. ahref(cols[1], back, arg) .. esc(after)
                    else
                        -- sauts divers
                        local before,addr,after = n:match('^(.*%$)(%x%x%x%x)(.*)$')
                        if addr and mem[tonumber(addr,16)] then 
                            n = esc(before) .. ahref(cols[1], addr,addr) .. esc(after)
                        else
                            n = esc(n)
                        end
                        -- if addr then n = n .. EQUATES:t(addr) end
                    end
                    t = t .. n
                end
                t = t .. '</' .. tag .. '>'
            end
            w('    <tr', t , '</tr>\n')
        end,
        header = function(self, columns)
            self.ncols = #columns
            
            local cols,align,align_style={},{['<'] = 'left', ['='] = 'center', ['>'] = 'right'},''
            for i,n in ipairs(columns) do
                local tag = n:match('^([<=>])')
                cols[i] = trim(tag and n:sub(2) or n)
                align_style = align_style ..
                    '    #t1 td:nth-of-type(' .. i .. ') {text-align: ' .. align[tag or '<'] ..  ';' ..
                    ((i==1 or i==4) and ' font-weight: bold;' or '') .. '}\n'
            end
         
            w([[<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>DCMoto_MemMap</title>
  <style>
    :target {background-color:lightgray;}
    table {
      border-collapse: collapse;
      border-top: 1px solid #ddd;
      border-bottom: 1px solid #ddd;
      width: 100%;
    }
    th, td {
      padding-left: 8px;
      padding-right: 8px;
      border-left: 1px solid #ddd;
      border-right: 1px solid #ddd;
    }
    th {
      background-color:lightgray;
      border-bottom: 1px solid #ddd;
    }
    tr:hover {
      background-color:lightgray;
    }
    #main {
      overflow: auto;
      width:    auto;
      height:   100vh;
    }
    #memmap {
      overflow: auto;
      width:    100%;
      height:   100vh;
    }
    #memmap a {
      cursor:   crosshair;
    }
    #loading {
      position: fixed;
      display: none;
      justify-content: center;
      align-items: center;
      width: 100%;
      height: 100%;
      top: 0;
      left: 0;
      opacity: 0.7;
      background-color: #000;
      z-index: 99;
      cursor: wait;
    }
    #closeButton {
      color: black;
      background-color: white;
      z-index: 100;
      display: block;
      padding: 0.6em;
      font-size: 2em;
      font-weight: bold;
      cursor: pointer;
    }
    #TOP, #BOTTOM             {text-decoration: none;}
    #TOP:hover, #BOTTOM:hover {background-color: yellow;}
    .c0 {background-color:#111;}
    .c1 {background-color:#e11;}
    .c2 {background-color:#1e1;}
    .c3 {background-color:#ee1;}
    .c4 {background-color:#11e;}
    .c5 {background-color:#e1e;}
    .c6 {background-color:#1ee;}
    .c7 {background-color:#eee;}
    .mm {table-layout: fixed;}
    .mm tr:hover {background-color:initial;}
    .mm a {text-decoration:none; display: block; height:100%; width:100%;}
    .mm td {padding:0; border: 1px solid #ddd; width: ]],100/MAPCOL,'%; height: ',100/MAPCOL,'vh;}\n',
    align_style, MAP and '    body {overflow: hidden; margin: 0; display:flex;}\n',[[
  </style>
</head>
<body>
  <script>
    function on(event, color) {
        document.addEventListener(event,function(event) {
            if(event.target.tagName==="A") {
                const id  = event.target.getAttribute("href").substring(1);
                const elt = document.getElementById(id);
                if(elt!==null) {
                    document.getElementById(id).style.background = color;
                }
            }
        });
    }
    on('mouseover', 'yellow');
    on('mouseout',  null);
    function hideLoading() {
        const loading = document.getElementById("loading");
    if(loading!==null) {
            loading.style.display = "none";
            document.body.removeChild(loading);
    }
  }
  </script>
  <div id="loading">
    <button id="closeButton" onclick="hideLoading()" title="click to close" class="h1">
      &nbsp;
    </button>
  </div>
  <script>
    function progress(percent) {
      var txt = "Please wait while loading...";
      if(percent>0) txt = txt + '<br>(' + percent + '%)';
      document.getElementById('closeButton').innerHTML = txt;
    }
    progress(0);
    document.getElementById('loading').style.display = 'flex';
  </script>]])
            w(MAP and '  <div id="main">\n' or '',
              '  <h1>Analysis of ',TRACE,' between $',hex(MINADR),' and $',hex(MAXADR),'</h1>\n',
              '  <a href="#BOTTOM" id="TOP">&darr;&darr;goto bottom&darr;&darr;</a>\n',
              '  <div><p></p></div>\n',
              '  <table id="t1" style="font-family: monospace;">\n')
            if self.ncols>0 then self:_row("th", cols) end
            return self
        end,
        row = function(self, cels)
            self:_row('td', cels)
            return self
        end
    }
end

------------------------------------------------------------------------------
-- detecte les points chauds (endroits où l'on passe le plus de temps)
------------------------------------------------------------------------------

local function findHotspots(mem)
    local spots,hot = {}
    local function newHot(i) 
        return {
            x = 0, t = 0, a = hex(i),
            touches = function(self,m)
                return math.abs(m.x - self.x)<=1
            end,
            add = function(self,m)
                self.x = m.x
                if m.asm then
                    local cycles = tonumber(m.asm:match('%((%d+)')) or 0
                    self.t = self.t + m.x * cycles
                end
                return self
            end,
            push = function (self, spots) 
                -- print(self.a, self.x, self.t)
                table.insert(spots, self)
                return nil
            end
        } 
    end
    for i=MINADR,MAXADR do
        local m = mem[i] 
        if not m then
            if hot then hot = hot:push(spots) end
        elseif hot and hot:touches(m) then
            hot:add(m)
        else
            if hot and not hot:touches(m) then hot = hot:push(spots) end
            if m.asm then hot = newHot(i):add(m) end
        end
    end
    table.sort(spots, function(a,b) return a.t > b.t end)
    return spots
end

------------------------------------------------------------------------------
-- analyseur de mémoire
------------------------------------------------------------------------------

local mem = {
    -- accesseur privé à une case mémoire
    _get = function(self, i)
        local t = self[i % 65536]
        if not t then t={r=NOADDR,w=NOADDR,x=0,asm=nil} self[i] = t end
        return t
    end,
    -- positionne le compteur programme courrant
    pc = function(self, pc)
        self.PC = hex(pc)
        return self
    end,
    -- assigne un code asm au PC courrant
    a = function(self, asm)
        local pc = tonumber(self.PC,16)
        asm = trim(asm)
        if asm then self:_get(pc).asm = asm end
        return self
    end,
    -- marque les octets "hexa" comme executés "num" fois
    x = function(self,hexa,num)
        local pc = tonumber(self.PC,16)
        for i=0,hexa:len()/2-1 do local m = self:_get(pc+i); m.x = m.x + num end
        return self
    end,
    -- marque "addr" comme lue depuis le compteur programme courant
    r = function(self, addr, len)
        for i=0,(len or 1)-1 do self:_get(addr+i).r = self.PC end
        return self
    end,
    -- marque "addr" comme écrite depuis le compteur programme courant
    w = function(self, addr, len)
        for i=0,(len or 1)-1 do self:_get(addr+i).w = self.PC end
        return self
    end,
    -- charge un fichier TAB Separated Value (CSV avec des tab)
    loadTSV = function(self, f)
        if f then
            for s in f:lines() do
                local pc,r,w,x,a = s:match('(%x+)%s+([01])%s+([-%x]+)%s+([-%d]+)%s+(.*)$')
                if pc then
                    if x~='-'    then self:pc(pc):x('12',x):a(a) end
                    if r~=NOADDR then self:pc(r):r(pc)   end
                    if w~=NOADDR then self:pc(w):r(pc)   end
                end
            end
        else
            f = {close=function() end}
        end
        return f
    end,
    -- écrit un fichier en utilisant le writer fourni
    save = function(self, writer)
        writer = writer or newParallelWriter()
        
        writer:header{"Addr   ", "RdFrom ", "WrFrom ", "> ExeCnt", "<Asm code"}

        local n,curr=0,0
        local function u(space)
            if n>0 then
                if space<0 then writer:row{} end
                writer:row{{'%d byte%s untouched', n, n>1 and 's' or ''}}
                if space>0 then writer:row{} end
                n = 0
             end
        end
        for i=MINADR,MAXADR do
            local m=self[i]
            if m then
                local mask = ((m.r==NOADDR or m.asm) and 0 or 1) + (m.w==NOADDR and 0 or 2) + (m.x==0 and 0 or 4)
                if mask ~= curr or (m.asm and m.r~=NOADDR) then writer:row{} end curr = mask
                u(1)
                if mask~=4 or m.asm then
                    writer:row{hex(i), m.r, m.w, m.x==0 and '-' or m.x,m.asm or ''}
                end
            else
                n, curr = n + 1, 0
            end
        end
        u(-1)
        
        -- hotspot
        local spots,total,count,first = findHotspots(self),0,0,true
        for i,s in ipairs(spots) do total = total + s.t end
        for i,s in ipairs(spots) do 
            if first then   
                first = false
                writer:row{}
                writer:row{{'Hot spots (runtime: ~%.2fs)', total/1000000}}
                writer:row{}
            end
            writer:row{'     ', {'  #%-4d',i},s.a,{'%5d',s.x},{'%5.2f%% (%.3gs)',  100*s.t/total, s.t/1000000}}
            count = count + s.t
            if i>=3 and count >= .8 * total then break end
        end
        return writer
    end
}

------------------------------------------------------------------------------
-- Programme principal: analyse le fichier de trace
------------------------------------------------------------------------------

-- décode une adresse dans les arguments "args" d'une instruction
function getaddr(args, regs)
    local a,x
    
    -- immediate --> retour nil
    if args:sub(1,1)=='#' then return end

    -- traite les indirect comme un extended (c'est pas parfait, mais bon)
    if args:sub(1,1)=='[' then args = args:sub(2,-2) end
        
    -- retrouve un registre dans la liste des valeurs de registres
    local function reg(x)
        return tonumber(
            x=='A' and regs:match('D=(%x%x)') or
            x=='B' and regs:match('D=..(%x%x)') or
            regs:match(x..'=(%x+)'),16)
    end
    
    -- extension de signe
    local function sex(a) return a>=128 and a-256 or a end

    -- DP & Extended
    x = args:match('<%$(%x%x)$')     if x then return tonumber(x,16)+reg('DP')*256 end
    x = args:match('^%$(%x%x%x%x)$') if x then return tonumber(x,16) end

    -- Indexé
    x   = args:match('^,([XYUS])')              if x then return reg(x) end
    x   = args:match(',%-([XYUS])$')            if x then return add16(reg(x),-1) end
    x   = args:match(',%-%-([XYUS])$')          if x then return add16(reg(x),-2) end
    a,x = args:match('^([D]),([XYUS])$')        if a and x then return add16(reg(x),reg(a)) end
    a,x = args:match('^([AB]),([XYUS])$')       if a and x then return add16(reg(x),sex(reg(a))) end
    a,x = args:match('^%$(%x%x),([XYUS])$')     if a and x then return add16(reg(x),sex(tonumber(a,16))) end
    a,x = args:match('^%-$(%x%x),([XYUS])$')    if a and x then return add16(reg(x),-sex(tonumber(a,16))) end
    a,x = args:match('^%$(%x%x%x%x),([XYUS])$') if a and x then return add16(reg(x),tonumber(a,16)) end

    -- TODO PCR ?
    error(args)
end
-- getaddr = memoize:make(getaddr)

-- Auxiliaire qui marque les adresses pointée par "ptr" comme
-- lues (dir>0) ou écrits (dir<0) en fonction des arguments de
-- l'opération de pile
local function stack(ptr, dir, args)
    ptr = tonumber(ptr,16)
    local function mk(len)
        if dir>0 then mem:r(ptr, len) else mem:w(add16(ptr,-len), len) end
        ptr = add16(ptr,dir*len)
    end
    if args:match('A')  then mk(1) end
    if args:match('B')  then mk(1) end
    if args:match('CC') then mk(1) end
    if args:match('DP') then mk(1) end
    if args:match('X')  then mk(2) end
    if args:match('Y')  then mk(2) end
    if args:match('S')  then mk(2) end
    if args:match('U')  then mk(2) end
    if args:match('PC') then mk(2) end
    return ptr
end
-- lecture depuis la pile "reg"
local function pull(reg, args, regs)
    stack(regs:match(reg..'=(%x%x%x%x)'), 1,args)
end
-- écriture depuis la pile "reg"
local function push(reg, args, regs)
    stack(regs:match(reg..'=(%x%x%x%x)'),-1,args)
end

------------------------------------------------------------------------------
-- type d'instructions:
------------------------------------------------------------------------------

-- a) lecture 1 octet
local R8  = set{'ADCA','ADCB','ADDA','ADDB','ANDA','ANDB','ANDCC',
                'BITA','BITB','CMPA','CMPB','EORA','EORB',
                'LDA','LDB','ORA','ORB','SBCA','SBCB','SUBA','SUBB','TST'}
-- b) écriture 1 octet
local W8 = set{'CLR','STA','STB'}
-- c) lecture/écriture 1 octet
local RW8 = set{'ASL','ASR','COM','DEC','INC','LSL','LSR','NEG','ROL','ROR'}
-- d) lecture 2 octets
local R16 = set{'ADDD','CMPD','CMPX','CMPY','CMPU','CMPS','LDD','LDX','LDY','LDU','LDS'}
-- e) écriture 2 octets
local W16 = set{'STD','STX','STY','STU','STS'} --'JSR','BSR','LBSR'}

-- code hexa propre à DCMOTO pour les I/ORA
local DCMOTO_RESERVED = {
    ['11EC'] = "K7BIT",
    ['11ED'] = "K7RD",
    ['11EE'] = "K7WR",
    ['11F2'] = "DKWR",
    ['11F3'] = "DKRST",
    ['11F4'] = "DKFMT",
    ['11F5'] = "DKRD",
    ['11F8'] = "MPOS",
    ['11F9'] = "MBTN",
    ['11FA'] = "OPRT",
    ['11FC'] = "KBRD",
    ['11FD'] = "KBWR",
    ['11FE'] = "NETWR",
    ['11FF'] = "INPEN",
nil}

-- lecture ancien fichier si pas reset
if not RESET then mem:loadTSV(io.open(RESULT .. '.csv','r')):close() end

-- attente d'un fichier
local function wait_for_file(filename)
    out('Waiting for %s...', filename)
    while not os.rename(filename,filename) do
        if os.getenv('COMSPEC') then -- windows
            os.execute('ping -n 1 127.0.0.1 >NUL')
        else
            local t=os.clock() + 1
            repeat until os.clock()>=t
        end
    end
    out('\r                                                 \r')
end

-- ouverture et analyse du fichier de trace
local function read_trace(filename)
    local num,f = 0, assert(io.open(filename,'r'))
    local size = f:seek('end') f:seek('set')

    local pc,hexa,opcode,args,regs,sig,jmp,curr_pc
    local nomem = {} -- cache des codes hexa ne touchant pas la mémoire (pour aller plus vite)
    local jmp = nil -- pour tracer d'où l'on vient en cas de saut
    local function maybe_indirect()
        if args:sub(1,1)=='[' then
            local a = getaddr(args,regs) 
            if a then mem:r(a,2) end
        end
    end
    local DISPATCH = {
        ['???']  = function() opcode = DCMOTO_RESERVED[hexa] or opcode; nomem[sig] = true end,
        ['PULS'] = function() pull('S',args,regs) end,
        ['PSHS'] = function() push('S',args,regs) end,
        ['PULU'] = function() pull('U',args,regs) end,
        ['PSHU'] = function() push('U',args,regs) end,
        ['BSR']  = function() push('S','PC',regs) jmp = curr_pc end,
        ['LBSR'] = function() push('S','PC',regs) jmp = curr_pc end,
        ['JSR']  = function() push('S','PC',regs) maybe_indirect() jmp = curr_pc end,
        ['JMP']  = function() maybe_indirect() jmp = curr_pc end,
        ['RTS']  = function() pull('S','PC',regs) end,
        ['SWI']  = function() push('S','A/B/X/Y/U/CC/DP/PC',regs) end,
        ['RTI']  = function() pull('S','A/B/X/Y/U/CC/DP/PC',regs) end, -- take E flag of cc into account ?
        _ = function(self, set, fcn) for k in pairs(set) do self[k] = fcn end end
    }
    DISPATCH:_(R8,  function() local a = getaddr(args,regs) if a then mem:r(a) else nomem[sig] = true end end)
    DISPATCH:_(W8,  function() local a = getaddr(args,regs) if a then mem:w(a) else nomem[sig] = true end end)
    DISPATCH:_(RW8, function() local a = getaddr(args,regs) if a then mem:r(a):w(a) else nomem[sig] = true end end)
    DISPATCH:_(R16, function() local a = getaddr(args,regs) if a then mem:r(a,2) else nomem[sig] = true end end)
    DISPATCH:_(W16, function() local a = getaddr(args,regs) if a then mem:w(a,2) else nomem[sig] = true end end)
    
    local REL_BRANCH = {}
    for _,hexa in ipairs{'16','17','20','21','22','23','24','25','26','27','28','29','2C','2D','2E','2F',
        '1017','1020','1021','1022','1023','1024','1025','1027','1028','1029','102C','102D','102E','102F'} do
        for i=0,255 do REL_BRANCH[sprintf("%s%02X", hexa, i)] = true end
    end
    
    for s in f:lines() do
        -- print(s) io.stdout:flush()
        if 50000==num then num=0; out('%6.02f%%\r', 100*f:seek()/size) end
        num,pc,hexa,opcode,args = num+1,s:sub(1,42):match('(%x+)%s+(%x+)%s+(%S+)%s+(%S*)%s*$')
        -- local pc,hexa,opcode,args = s:sub(1,4),trim(s:sub(6,15)),s:sub(17,42):match('(%S+)%s+(%S*)%s*$')
         -- print(pc, hexa, opcode, args)
        if opcode then
            -- print(pc,hex,opcode,args)
            curr_pc = tonumber(pc,16)
            if jmp then mem:pc(jmp):r(curr_pc) jmp = nil end
            mem:pc(curr_pc):x(hexa,1)
            sig = 
                -- pc .. '.' .. hexa
                -- hexa if REL_BRANCH[sig] then sig = pc .. ':' .. hexa end
                REL_BRANCH[hexa] and pc..':'..hexa or hexa
            if nomem[sig] then 
                mem:a(nomem[sig])
            else
                regs = s:sub(61,106)
                local f = DISPATCH[opcode] if f then f() else nomem[sig] = true end
                -- on ne connait le code asm vraiment qu'à la fin
                local asm, cycles = 
                    args=='' and opcode or sprintf("%-5s %s", opcode, args),
                    "(" .. trim(s:sub(43,46)) .. ")"
                asm = sprintf("%-5s %s%s%s", cycles, asm, EQUATES:t(args:match('%$(%x%x%x%x)')), EQUATES:t(pc))
                if nomem[sig] then nomem[sig] = asm end
                mem:pc(curr_pc):a(asm)
            end
        end
    end
    f:close()
    out('                \r')
end

------------------------------------------------------------------------------
-- boucle principale (sortie par ctrl-c)
------------------------------------------------------------------------------
repeat
    -- attente de l'arrivée d'un fichier de trace
    wait_for_file(TRACE)
    -- lecture fichier de trace
    read_trace(TRACE)
    -- écriture résultat TSV & html
    mem:save(newParallelWriter( 
        newTSVWriter (assert(io.open(RESULT .. '.csv', 'w'))),
        HTML and newHtmlWriter(assert(io.open(RESULT .. '.html','w')), mem) or nil
    )):close()
    -- effacement fichier trace consomé
    if LOOP then assert(os.remove(TRACE)) end
until not LOOP