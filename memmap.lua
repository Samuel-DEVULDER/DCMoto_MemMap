------------------------------------------------------------------------------
-- memmap.lua : Outil d'analye de traces DCMoto par S. Devulder.
--
-- Usage:
--     lua.exe memmap.lua [-reset] [-loop]
--                        [-from=XXXX] [-to=XXXX]
--                        [-equates] [-mach=(mo|to|??)]
--                        [-html [-map[=NBCOLS]]]
--                        [-verbose[=N]]
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
-- L'option '-equates' ajoute une annotation concernant un equate thomson
-- reconnu dans les adresses.
--
-- L'option '-mach=TO' ou '-mach=MO' selectionne un type de machine. La
-- zone analysée correspond alors à la seule RAM utilisateur du type de
-- machine choisie. Les "equates" sont aussi restreints aux seuls equates
-- correspondant à la machine choisie. L'option '-mach=??' essaye de 
-- deviner le type de machine.
--
-- L'option '-verbose' ou '-verbose=N' affiche des détails supplémentaires.
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
-- Si aucune instruction n'a lu (ou écrit à) cette adresse alors un "----"
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
-- $Version$ $Date$
------------------------------------------------------------------------------

local NOADDR = '----'                  -- marqueur d'absence
local TRACE  = 'dcmoto_trace.txt'      -- fichier trace
local RESULT = 'memmap'                -- racine des fichiers résultats
local BRAKET = {' <-',''}              -- pour décorer les equates
-- local BRAKET = {' .oO(',')'}
-- local BRAKET = {' (',')'}
-- local BRAKET = {'<<',''}

local MACH_XX     = '?'                -- deviner la machine
local MACH_TO     = "TO."              -- TO7 etc.
local MACH_MO     = "MO."              -- MO5 etc.

local OPT_LOOP    = false              -- reboucle ?
local OPT_RESET   = false              -- ignore les analyses précédentes ?
local OPT_MIN     = nil                -- adresse de départ
local OPT_MAX     = nil                -- adresse de fin
local OPT_MAP     = false              -- ajoute une version graphique de la map
local OPT_HTML    = false              -- produit une analyse html?
local OPT_COLS    = 128                -- nb de colonnes de la table map
local OPT_EQU     = false              -- utilise les equates
local OPT_MACH    = nil                -- type de machine
local OPT_VERBOSE = 0                  -- niveau de détail

------------------------------------------------------------------------------
-- utilitaires
------------------------------------------------------------------------------

local unpack = unpack or table.unpack

-- formatage à la C
local function sprintf(...)
    return string.format(...)
end

-- affiche un truc sur la sortie d'erreur (pas de buffferisation)
local function out(fmt, ...)
    io.stderr:write(sprintf(fmt, ...))
    io.stderr:flush()
end

-- affiche un truc si le niveau de détail est suffisant
local function verbose(level, fmt, ...)
    if level <= OPT_VERBOSE then out(fmt, ...) end
end

-- un simple verbose de niveau 1
local function log(fmt, ...)
    verbose(1, fmt .. '\n', ...)
end

-- profiling
local profile = {clk=nil, lvl = 2,
    _ = function(self, msg)
        if self.lvl<=OPT_VERBOSE then
            if self.clk then
                local time = os.clock() - self.clk; self.clk = nil
                verbose(self.lvl, 'done (%.3gs)\n', time)
            else
                msg = msg or 'Running ' .. debug.getinfo(2, "n").name .. '()'
                verbose(self.lvl, "%s...", msg)
                self.clk = os.clock()
            end
        end
    end
}

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

-- affiche l'usage
local function usage(errcode, short)
    local f = assert(io.open(arg[0],'r'))
    local empty = 0
    for l in f:lines() do
        l = trim(l); if l==nil or l=='' then break end
        l = l:match('^%-%- (.*)$') or l:match('^%-%-(%s?)$')
        if l=='' then empty = empty + 1; if empty==2 then break end end
        if l then io.stdout:write(l .. '\n') end
    end
    f:close()
    os.exit(errocode or 5)
end

------------------------------------------------------------------------------
-- Analyse la ligne de commande
------------------------------------------------------------------------------

local function machTO() 
    OPT_MACH,OPT_MIN,OPT_MAX,OPT_EQU = MACH_TO,OPT_MIN or 0x6100,OPT_MAX or 0xDFFF,true 
    log("Set machine to %s", OPT_MACH) 
end
local function machMO() 
    OPT_MACH,OPT_MIN,OPT_MAX,OPT_EQU = MACH_MO,OPT_MIN or 0x2100,OPT_MAX or 0x9FFF,true 
    log("Set machine to %s", OPT_MACH) 
end

for i,v in ipairs(arg) do local t
    v = v:lower()
    if v=='-h'
    or v=='?'
    or v=='--help'   then usage()
    elseif v=='-loop'    then OPT_LOOP    = true
    elseif v=='-html'    then OPT_HTML    = true
    elseif v=='-reset'   then OPT_RESET   = true
    elseif v=='-map'     then OPT_MAP     = true
    elseif v=='-equates' then OPT_EQU     = true
    elseif v=='-verbose' then OPT_VERBOSE = 1
    elseif v=='-mach=??' then OPT_MACH    = MACH_XX; OPT_EQU = true
    elseif v=='-mach=to' then machTO()
    elseif v=='-mach=mo' then machMO()
    else t=v:match('%-from=(%x+)')     if t then OPT_MIN     = tonumber(t,16)
    else t=v:match('%-to=(%x+)')       if t then OPT_MAX     = tonumber(t,16)
    else t=v:match('%-map=(%d+)')      if t then OPT_COLS    = tonumber(t)
    else t=v:match('%-verbose=(%d+)')  if t then OPT_VERBOSE = tonumber(t)
    else io.stdout:write('Unknown option: ' .. v .. '\n\n'); usage(21, true)
    end end end end end
end

------------------------------------------------------------------------------
-- Quelques adresses bien connues
------------------------------------------------------------------------------

local EQUATES = {
    _mach = '',
    m = function(self,mach)
        self._mach = mach or ''
        return self
    end,
    -- sets a page prefix to adress
    _page = '',
    p = function(self,page)
        self._page = page or ''
        return self
    end,
    -- define adresses
    d = function(self,addr,name, ...)
        if addr then
            self[self._page .. addr] = ((OPT_MACH==nil or OPT_MACH==MACH_XX) and self._mach or '') .. name
            self:d(...)
        end
        return self
    end,
    -- define adresses in sequence
    s = function(self, addr, name, ...)
        if addr then
            if name then self:d(addr,name) end
            self:s(hex(add16(tonumber(addr,16),1)), ...)
        end
        return self
    end,
    -- get text
    t = function(self,addr,add2)
        return OPT_EQU 
        and (self[addr or ''] and BRAKET[1]..self[addr]..BRAKET[2]
        or   self[add2 or ''] and BRAKET[1]..self[add2]..BRAKET[2]
        or   '')
    end,
    -- init equates for video ram
    iniVRAM = function(self, base)
        for i=0,8191 do local j,t
          i,j,t = math.floor(i/40),i%40,'VRAM'
          if i>0 then t = t..'.L'..i end
          if j>0 then t = t..'+'..j end
          self:d(hex(base+i*40+j),t)
        end
        return self
    end,
    -- init TO equates
    iniTO = function(self) self
        :m(MACH_TO)
        :iniVRAM(0x4000)
        -- TO9 monitor
        :d('EC0C','EXTRA',
           'EC09','PEIN',
           'EC06','GEPE',
           'EC03','COMS',
           'EC00','SETP',
           nil)
        -- TO7 monitor
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
        -- Redir moniteur TO
        :d('6000','REDIR.GETLP',
           '6002','REDIR.LPIN',
           '6004','REDIR.GETP',
           '6006','REDIR.GACH',
           '6008','REDIR.PUTC',
           '600A','REDIR.GETC',
           '600C','REDIR.DRAW',
           '600E','REDIR.PLOT',
           '6010','REDIR.RSCONT',
           '6012','REDIR.GETP',
           '6014','REDIR.GETS',
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
        :d('E000','DKROMID',
           'E001','DKFATSZ',
           'E002','DKSECSZ',
           'E003','DKCKSUM',
           'E004','DKCON',
           'E007','DKBOOT',
           'E00A','DKFMT',
           'E00D','LECFA',
           'E010','RECFI',
           'E013','RECUP',
           'E016','ECRSE',
           'E019','ALLOD',
           'E01C','ALLOB',
           'E01F','MAJCL',
           'E022','FINTR',
           'E025','QDDSYS',
           nil)
        -- 6846 système
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
        -- i/o palette IGV9369
        :d('E7DA','PALDAT',
           'E7DB','PALDAT/IDX',
           nil)
        -- gate array affichage
        :d('E7DC','LGAMOD',
           'E7DD','LGATOU',
           nil)
        -- 6850 système (clavier TO9)
        :d('E7DE','SCR/SSDR',
           'E7DF','STDR/SRDR',
           nil)
        -- gate array système
        :d('E7E4','LGASYS2',
           'E7E5','LGARAM',
           'E7E6','LGAROM',
           'E7E7','LGASYS1',
           nil)
    end,
    -- init MO equates
    iniMO = function(self) self
        :m(MACH_MO)
        :iniVRAM(0x0000)
        -- http://pulko.mandy.pagesperso-orange.fr/shinra/mo5_memmap.shtml
        :d('2000','TERMIN',
           '2019','STATUS',
           '201A','TABPT',
           '201B','RANG',
           '201C','COLN',
           '201D','TOPTAB,',
           '201E','TOPRAN',
           '201F','BOTTAB',
           '2020','BOTRAN',
           '2021','SCRPT',
           '2023','STADR',
           '2025','ENDDR',
           '2027','BLOCZ',
           '2029','FORME',
           '202A','ATRANG', 
           '202B','COLOUR',
           '202C','PAGFLG',
           '202D','SCROLS',
           '202E','CURSFL',
           '202F','COPCHR',
           '2030','EFCMPT',
           '2031','ITCMPT',
           '2032','PLOTX',
           '2034','PLOTY',
           '2036','CHDRAW',
           '2037','KEY',
           '2038','CMPTKB',
           '203A','TEMPO',
           '203C','DUREE',
           '203D','WAVE',
           '203E','OCTAVE',
           '2040','K7DATA',
           '2041','K7LENG',
           '2042','PROPC',
           '2043','PRSTA',
           '2044','TEMP',
           '2046','SAVEST',
           '2048','DKOPC',  
           '2049','DKDRV',
           '204A','DKTRK',
           '204B','DKTRK+1',
           '204C','DKSEC',
           '204D','DKNUM',
           '204E','DKSTA',
           '204F','DKBUF',
           '2051','DKTMP',
           '2059','SEQUCE',
           '205A','US1',
           '205B','ACCENT',
           '205C','SS2GET',
           '205D','SS3GET',
           '205E','SWIPT',
           '2061','TIMEPT',
           '2063','SEMIRQ',
           '2064','IRQPT',
           '2067','FIRQPT',
           '206A','SIMUL',
           '206D','CHRPTR',
           '2070','USERAF',
           '2073','GENPTR',
           '2076','LATCLV',
           '2077','GRCODE',
           '2078','DECALG',
           '207F','DEFDST',
           '2080','DKFLG',
           '2082','SERDAT',
           '2081','SYS.STK.LO',
           '20CC','SYS.STK.HI',
           '20CD','LPBUFF',
           '20FE','FSTRST',
           '2113','BASDEB',
           '2115','BASFIN',
           '2117','BASVAR',
           '2119','BASTAB',
           '2199','LDTYPE',
           '219B','LDBIN',
           '219C','LDADDR',
           '23FA','FILENAME',
           nil)
        -- minidos
        :d('A000','DKROMID',
           'A001','DKFATSZ',
           'A002','DKSECSZ',
           'A003','DKCKSUM',
           'A004','DKCON',
           'A007','DKBOOT',
           'A00A','DKFMT',
           'A00D','LECFA',
           'A010','RECFI',
           'A013','RECUP',
           'A016','ECRSE',
           'A019','ALLOD',
           'A01C','ALLOB',
           'A01F','MAJCL',
           'A022','FINTR',
           'A025','QDDSYS',
           nil)
        -- PIA système
        :d('E7C0','PRA',
           'E7C1','PRB',
           'E7C2','CRA',
           'E7C3','CRB',
           nil)
        :d('E7CB','MEMCTR',
           nil)
        -- 6021 musique & jeux
        :d('A7CC','PRA1',
           'A7CD','PRA2',
           'A7CE','CRA1',
           'A7CF','CRA2',
           nil)
        -- i/o palette IGV9369
        :d('A7DA','PALDAT',
           'A7DB','PALDAT/IDX',
           nil)
        -- gate array système
        :d('A7E4','LGASYS2',
           'A7E5','LGARAM',
           'A7E6','LGAROM',
           'A7E7','LGASYS1',
           nil)
        -- Basic
        :d('CE2C','PUTS',
           'D83E','PUTD',
           'E076','SETNAME',
           'E079','SETEXT',
           'E088','FILETYPE',
           'E0B9','PROTEC',
           'E12B','SAVEBAS',
           'E167','SAVEBIN',
           'E2B3','LOADFILE',
           nil)
    end,
    ini = function(self)
        for k,v in pairs(self) do if k:match('^%x%x%x%x$') then self[k] = nil end end
        self
        :d('FFFE','VEC.RESET',
           'FFFC','VEC.NMI',
           'FFFA','VEC.SWI',
           'FFF8','VEC.IRQ',
           'FFF6','VEC.FIRQ',
           'FFF4','VEC.SWI2',
           'FFF2','VEC.SWI3',
           'FFF0','VEC.MACH')
        local setMO = set{MACH_XX, MACH_MO}
        local setTO = set{MACH_XX, MACH_TO}
        if setMO[OPT_MACH or MACH_XX] then self:iniMO() end
        if setTO[OPT_MACH or MACH_XX] then self:iniTO() end
    end,
nil} EQUATES:ini()

------------------------------------------------------------------------------
-- différent formateurs de résultat
------------------------------------------------------------------------------

-- Writer Parallèle
local function newParallelWriter(...)
    log('Created Parallel writer.')
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
    log('Created CSV writer (tab=%d).', tablen)
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

-- Writer OPT_HTML (quelle horreur!)
local function newHtmlWriter(file, mem)
    log('Created HTML writer.')
    HEADING = "h1"
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
        :gsub("&lt;%-", "&larr;") --:gsub("%-&gt;", "&rarr;")
        :gsub(' ','&nbsp;')
    end
    -- récup des adresses utiles
    local valid = {} for i=OPT_MIN,OPT_MAX do 
        local m = mem[i]
        if m and (m.asm or m.x==0) then valid[hex(i)] = true end
    end
    local rev   = {}
    for i=OPT_MAX,OPT_MIN,-1 do
        local m = mem[i]
        if m and not m.s then
            i = hex(i)
            if m.w~=NOADDR and valid[m.w] then rev[m.w] = i end
            if m.r~=NOADDR and valid[m.r] then rev[m.r] = i end
        end
    end
    -- sort le code html pour la progression
    local prog_next = .01
    local function progress(ratio)
        if ratio >= prog_next then
            prog_next = prog_next + .01
            w(sprintf('\n<script>progress(%d);</script>\n\n', math.floor(100*ratio)))
        end
    end
    -- descrit le contenu d'une adresse
    local function describe(addr, opt_asm, opt_asm_addr, opt_from)
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
                           (m.w==NOADDR and '-' or 'W')..
                           (m.s and 'S' or '')
            --
            local anchor = addr
            if opt_asm_addr and (RWX=='X--' or (RWX=='XR-' and m.asm)) then anchor = opt_asm_addr
            elseif RWX=='-RW' and m.r==m.w      then anchor = m.r
            elseif RWX=='-R-' and m.r~=opt_from then anchor = m.r
            elseif RWX=='--W' and m.w~=opt_from then anchor = m.w
            elseif RWX=='-RW' and m.r==opt_from then anchor = m.w 
            elseif RWX=='-RW' and m.w==opt_from then anchor = m.r end
            --
            local equate = EQUATES:t(addr)
            local equate_ptn = equate:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]','%%%1')
            local title  = '$' .. addr .. ' : ' .. RWX .. equate .. 
                           (opt_asm and '\n' .. opt_asm:gsub(equate_ptn,'') or '') ..
                           code(m.r):gsub(equate_ptn,'')
            if m.r~=m.w then title = title .. code(m.w):gsub(equate_ptn,'') end

            return title, RWX, anchor
        else
            return '$' .. addr .. ' : untouched' .. EQUATES:t(addr), '---', addr
        end
    end
    -- affiche le code html pour un hyperlien sur "addr" avec le texte
    -- "txt" (le tout pour l'adresse "from")
    local function ahref(from, addr, txt)
        local title, RWX, anchor = describe(addr,nil,nil,from)
        -- if from == anchor then anchor = addr end -- no loop back XXXX
		local function esc2(title)
			local x = esc(title)
			if mem[tonumber(from,16) or ''] and addr and addr~=from then
				local arr = '&' .. (addr <= from and 'u' or 'd') .. 'arr;'
				x = x:gsub(':', arr .. arr, 1)
			end
			return x
		end
        return valid[anchor] and '<a href="#' .. anchor .. '" title="' .. esc2(title) .. '">' .. esc(txt) .. '</a>'
                             or esc(txt)
    end

    local function memmap(mem)
        -- encodage des couleurs de cases
        local color = {
            ['---' ] = 7,
            ['--W' ] = 1,
            ['-R-' ] = 2,
            ['-RW' ] = 3,
            ['X--' ] = 4,
            ['X-W' ] = 5,
            ['XR-' ] = 6,
            ['XRW' ] = 0,
            ['---S'] = 0,
            ['--WS'] = 0,
            ['-R-S'] = 0,
            ['-RWS'] = 0,
            ['X--S'] = 0,
            ['X-WS'] = 0,
            ['XR-S'] = 0,
            ['XRWS'] = 0
        }

        -- encodage si JS n'est pas supporté par le browser (Lynx, Links)
        local short = {
            ['---' ] = '-',
            ['--W' ] = 'W',
            ['-R-' ] = 'R',
            ['-RW' ] = 'M',
            ['X--' ] = 'X',
            ['X-W' ] = 'Z',
            ['XR-' ] = 'Y',
            ['XRW' ] = '#',
            ['---S'] = 'S',
            ['--WS'] = 'S',
            ['-R-S'] = 'S',
            ['-RWS'] = 'S',
            ['X--S'] = 'S',
            ['X-WS'] = 'S',
            ['XR-S'] = 'S',
            ['XRWS'] = 'S'
        }

        -- affine le min/max pour réduire la taille de la carte
        local min,max = OPT_MIN,OPT_MAX
        for i=min,OPT_MAX    do if mem[i] then min=i break end end
        for i=OPT_MAX,min,-1 do if mem[i] then max=i break end end
        min,max = math.floor(min/OPT_COLS)*OPT_COLS,math.floor(max/OPT_COLS)*OPT_COLS+OPT_COLS-1
        
        w('  <',HEADING,'>Memory map: <code>$', hex(min), '</code> &rarr; <code>$', hex(max),'</code></',HEADING,'>\n')
        w('  <table class="mm">\n')
        local last_asm, last_asm_addr ='',''
        min,max = math.floor(min/OPT_COLS),math.floor(max/OPT_COLS)
        for j=min,max do
            w('    <tr>')
            for i=0,OPT_COLS-1 do
              local m,a = mem[OPT_COLS*j+i],hex(OPT_COLS*j+i)
              if m then
                  local title, RWX, anchor = describe(a, last_asm, last_asm_addr)
                  if m.asm then last_asm,last_asm_addr = m.asm, a end
                  w('<td', ' class="c', color[RWX],'"', ' title="',esc(title), '">',
                    '<a href="#',anchor,'">',
                    '<noscript>',short[RWX],'</noscript>',
                    '</a></td>')
              else
                w('<td class="c7" title="$',a,esc(EQUATES:t(a)),' : ---"><noscript>',short['---'],'</noscript></td>')
              end
            end
            w('</tr>\n')
            progress(.5 + .5*(j-min)/(max-min))
        end
        w('  </table>\n')
    end
    return {
        file=file,
        close = function(self)
            local f = self.file
            w('</table>\n',
              '<p></p>\n',
              '<a href="#TOP" id="BOTTOM" accesskey="t" title="Short cut : [Meta]-t">&uarr;&uarr; TOP &uarr;&uarr;</a>\n',
              '<',HEADING,'>End of analysis</',HEADING,'>\n')
            if OPT_MAP then
                w('</div>\n',
                  -- '<script>document.getElementById("progress").innerHTML  = "xxx"</script>\n',
                  '<div id="memmap">\n')
                memmap(mem)
                w('</div>')
            end
            w('<script>',
              'window.addEventListener("load", hideLoadingPage);',
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
            if last>1 then
                local adr = cols[1]:match("^%x%x%x%x$")
                if adr then
                    t = t .. ' id="'..adr..'"'
                    adr = tonumber(adr:match('^%x%x%x%x'),16)
                    if adr>=OPT_MIN and adr<=OPT_MAX then
                        progress((adr-OPT_MIN)/((OPT_MAX-OPT_MIN)*(OPT_MAP and 2 or 1)))
                    end
                end
            end
            t = t .. '>'
            for i,n in ipairs(cols) do
                t = t .. '<' .. tag ..
                    (i==last and i~=self.ncols and ' colspan="'..(self.ncols - i + 1)..'"' or '') ..
                    '>'
                if i==1 then
                    t = t .. esc(n)
                elseif i==2 or i==3 then
                    t = t .. ahref(cols[1],n,n)
                elseif i==4 then
                    t = t .. esc(n)
                elseif i==5 then
                    local back = rev[cols[1]]
                    if back then
                        local before,arg,after = n:match('^([%d/()]+%s*%S+%s+[%[<]?%$?)([%w_,]+)(.*)$')
                        if not arg then before,arg,after = n:match('^([%d/()]+%s*)([%w_,]+)(.*)$') end
                        if not arg then error(n) end
                        n = esc(before) .. ahref(cols[1], back, arg) .. esc(after)
                    else
                        -- sauts divers
                        local before,addr,after = n:match('^(.*%$)(%x%x%x%x)(.*)$')
                        if addr then
                            n = esc(before) .. ahref(cols[1], addr,addr) .. esc(after)
                        else
                            n = esc(n)
                        end
                    end
                    t = t .. n
                end
                t = t .. '</' .. tag .. '>'
            end
            w('    <tr', t , '</tr>')
            w('\n')
        end,
        header = function(self, columns)
            self.ncols = #columns

            local cols,align,align_style={},{['<'] = 'left', ['='] = 'center', ['>'] = 'right'},OPT_MAP and "    #t1 {width: 100%}\n" or ''
            for i,n in ipairs(columns) do
                local tag = n:match('^([<=>])')
                cols[i] = trim(tag and n:sub(2) or n)
                align_style = align_style ..
                    '    #t1 td:nth-of-type(' .. i .. ') {' ..
                    'text-align: ' .. align[tag or '<'] ..  ';' ..
                    ((i==1 or i==4) and ' font-weight: bold;' or '') ..
                    '}\n'
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
    }
    th, td {
      padding-left:  8px;
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
      flex-grow: 1;
      display: flex;
      flex-flow: column;
      overflow: auto;
      height:   100vh;
    }
    #memmap a {
      cursor:   default;
    }

    #loadingPage {
      position: fixed; top: 0; left:0; width:100%; height: 100%;
      display: none; justify-content: center; align-items: center;
    }
    #loadingGray {
      z-index: 99;
      position: fixed; top: 0; left:0; width:100%; height: 100%;
      opacity: 0.5; background-color: black;
      cursor: wait;
    }
    #loadingProgress {
      z-index: 100;
      display: block;
      padding: 0.6em;
      font-size: 2em;
      font-weight: bold;
      cursor: progress;
      color: black;
      background-color: #fefefe;
    }
    #loadingProgress:hover {background-color: #fefefe;}

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

    td.c0:hover {background-color:white;}
    td.c1:hover {background-color:black;}
    td.c2:hover {background-color:black;}
    td.c3:hover {background-color:black;}
    td.c4:hover {background-color:black;}
    td.c5:hover {background-color:black;}
    td.c6:hover {background-color:black;}
    td.c7:hover {background-color:black;}

    #t1 a:active {background-color:yellow;}

    .mm {table-layout: fixed;}
    .mm tr:hover {background-color:initial;}
    .mm a {text-decoration:none; display: block; height:100%; width:100%;}
    .mm td {padding:0; border: 1px solid #ddd; min-width:2px; min-height:2px; width: ]],100/OPT_COLS,'vh; height: ',100/OPT_COLS,'vh;}\n',
    align_style,
    OPT_MAP and '\n    body {overflow: hidden; margin: 0; display:flex; flex-flow:row;}\n' or '',[[
    
    @media (prefers-color-scheme: dark) {
      body {
        background-color: #1c1c1e;
        color: #fefefe;
      }
      a  {
        color: #6fb9ee; 
      }
      th, tr:hover, :target {color: black;background-color:#777;}
      #t1 a:active {background-color:#b70;}
      #loadingProgress {
        background-color: lightgray;
      }
    }  
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
                    const style = document.getElementById(id).style;
                    if(color!==null) {
                        style.background = color;
                        style.color = "black";
                    } else {
                        style.background =  null;
                        style.color = null;
                    }
                }
            }
        });
    }
    on('mouseover', window.matchMedia('(prefers-color-scheme: dark)').matches ? '#b70' : 'yellow');
    on('mouseout',  null);
    function hideLoadingPage() {
        const loading = document.getElementById("loadingPage");
        if(loading !== null) {
            loading.style.display = "none";
            document.body.removeChild(loading);
        }
    }
    function progress(percent) {
      const button = document.getElementById('loadingProgress')
      if(button !== null) {
        let txt = "Please wait while loading...";
        if(percent>=0) txt += '<br>(' + percent + '%)';
        button.innerHTML = txt;
      }
    }
  </script>
  <div id="loadingPage">
    <div id="loadingGray"></div>
    <button id="loadingProgress" onclick="hideLoadingPage()" title="click to access anyway" class="h1">
    </button>
  </div>
  <script>
    progress(0);
    document.getElementById('loadingPage').style.display = 'flex';
  </script>]])
            local MACH = {
                ['']      = 'All TO/MO',
                [MACH_XX] = 'Not decided yet',
                [MACH_MO] = 'MO5/MO6',
                [MACH_TO] = 'TO7(70)/TO8/TO9(+)'
            }
            w(OPT_MAP and '  <div id="main">\n' or '',
              '  <',HEADING,'>Analysis of <code>',TRACE,'</code></',HEADING,'>\n',
              '  <p></p>\n',
              '  <table>\n',
              '  <tr><th style="text-align: right">Machine:</th><td>', MACH[OPT_MACH or ''],'</td></tr>\n',
              '  <tr><th style="text-align: right">Range:</th><td><code>$', hex(OPT_MIN), '</code> &rarr; <code>$', hex(OPT_MAX), '</code></td></tr>\n',
              '  <tr><th style="text-align: right">Date:</th><td>', os.date('%Y-%m-%d %H:%M:%S'), '</td></tr>\n',
              '  </table>\n',
              '  <p></p>\n',
              '  <a href="#BOTTOM" id="TOP" accesskey="b" title="Short cut : [Meta]-b">&darr;&darr; BOTTOM &darr;&darr;</a>\n',
              '  <p></p>\n',
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

local REL_JMP = set{
	'BCC','BCS','BEQ','BGE','BGT','BHI','BHS','BLE','BLO','BLS','BLT','BMI','BNE','BPL','BRA','BRN','BVC','BVS',
	'LBCC','LBCS','LBEQ','LBGE','LBGT','LBHI','LBHS','LBLE','LBLO','LBLS','LBLT','LBMI','LBNE','LBPL','LBRA','LBRN','LBVC','LBVS'
}
local function findHotspots(mem)
    log('Finding hot spots.')
    profile:_()
	local spots,hot = {}
    local function newHot(i)
        return {
            x = 0, t = 0, a = hex(i), j=nil,
            touches = function(self,m)
                return math.abs(m.x - self.x)<=1
            end,
            add = function(self,m)
                self.x = m.x
                if m.asm then
                    local cycles = tonumber(m.asm:match('%((%d+)')) or 0
                    self.t = self.t + m.x * cycles
					local jmp,addr = m.asm:match('(%a+)%s+%$(%x%x%x%x)')
					if addr and (jmp=='JMP' or REL_JMP[jmp]) then self.j = addr end
                end
                return self
            end,
            push = function (self, spots)
                -- print(self.a, self.x, self.t)
                spots[self.a] = self
                return nil
            end
        }
    end
    for i=OPT_MIN,OPT_MAX do
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
	-- recolle les bouts 
	local changed
	repeat
		changed = false
		for k,h in pairs(spots) do 
			local j = spots[h and h.j or '']
			if j and j~=h then 
				spots[h.j] = nil
				h.t, h.j = h.t + j.t, j.j
				changed = true
			end
		end	
	until not changed
	-- cee une liste ordonnée
	local ret = {}
	for _,h in pairs(spots) do table.insert(ret, h) end
    table.sort(ret, function(a,b) return a.t > b.t end)
    profile:_()
    return ret
end

------------------------------------------------------------------------------
-- analyseur de mémoire
------------------------------------------------------------------------------

local mem = {
    -- accesseur privé à une case mémoire
    _get = function(self, i)
        local t = self[i % 65536]
        if nil==t then t={r=NOADDR,w=NOADDR,x=0,s=nil,asm=nil} self[i] = t end
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
    r = function(self, addr, len, stack)
        for i=0,(len or 1)-1 do local m = self:_get(addr+i)
            m.r, m.s = self.PC, stack
        end
        return self
    end,
    -- marque "addr" comme écrite depuis le compteur programme courant
    w = function(self, addr, len, stack)
        for i=0,(len or 1)-1 do local m = self:_get(addr+i)
            m.w, m.s = self.PC, stack 
        end
        return self
    end,
    _stkop = '***STACK***',
    -- charge un fichier TAB Separated Value (CSV avec des tab)
    loadTSV = function(self, f)
        if f then
            profile:_()
            for s in f:lines() do
                local pc,r,w,x,a = s:match('(%x+)%s+([-%x]+)%s+([-%x]+)%s+([-%d]+)%s+(.*)$')
                if pc then
                    local stkop = a==self._stkop; a = _stkop and ''or a
                    if x~='-'    then self:pc(pc):x('12',tonumber(x)):a(a) end
                    if r~=NOADDR then self:pc(r):r(pc,stkop)     end
                    if w~=NOADDR then self:pc(w):r(pc,stkop)     end
                end
            end
            profile:_()
        else
            f = {close=function() end}
        end
        return f
    end,
    -- écrit un fichier en utilisant le writer fourni
    save = function(self, writer)
        writer = writer or newParallelWriter()
        profile:_()

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
        for i=OPT_MIN,OPT_MAX do
            local m=self[i]
            if m then
                local mask = ((m.r==NOADDR or m.asm) and 0 or 1) + (m.w==NOADDR and 0 or 2) + (m.x==0 and 0 or 4)
                if mask ~= curr or (m.asm and m.r~=NOADDR) then writer:row{} end curr = mask
                u(1)
                if mask~=4 or m.asm then
                    writer:row{hex(i), m.r, m.w, m.x==0 and '-' or m.x,m.asm or (m.s and self._stkop) or ''}
                end
            else
                n, curr = n + 1, 0
            end
        end
        u(-1)
        profile:_()

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
    local usePC = args:match('PC')
    local stkop = usePC or args:match('DP')
    ptr = tonumber(ptr,16)
    local function mk(len)
        if dir>0 then mem:r(ptr, len, stkop) else mem:w(add16(ptr,-len), len, stkop) end
        ptr = add16(ptr,dir*len)
    end
    if usePC            then mk(2) end
    if args:match('U')  then mk(2) end
    if args:match('S')  then mk(2) end
    if args:match('Y')  then mk(2) end
    if args:match('X')  then mk(2) end
    if args:match('DP') then mk(1) end
    if args:match('CC') then mk(1) end
    if args:match('B')  then mk(1) end
    if args:match('A')  then mk(1) end
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
if not OPT_RESET then mem:loadTSV(io.open(RESULT .. '.csv','r')):close() end

-- attente d'un fichier
local function wait_for_file(filename)
    out('Waiting for %s...', filename)
    profile:_()
    while not os.rename(filename,filename) do
        if os.getenv('COMSPEC') then -- windows
            os.execute('ping -n 1 127.0.0.1 >NUL')
        else
            local t=os.clock() + 1
            repeat until os.clock()>=t
        end
    end
    profile:_()
    out('\r                                                 \r')
end

-- ouverture et analyse du fichier de trace
local function read_trace(filename)
    local num,f = 0, assert(io.open(filename,'r'))
    local size = f:seek('end') f:seek('set')

	local start_time = os.clock()

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

    local prev_hexa

    profile:_()
    for s in f:lines() do
        -- print(s) io.stdout:flush()
        if 50000==num then num = 0
            local txt = sprintf('%6.02f%%', 100*f:seek()/size)
            out('%s%s', txt, string.rep('\b', txt:len()))
        end

        num,pc,hexa,opcode,args = num+1,s:sub(1,42):match('(%x+)%s+(%x+)%s+(%S+)%s+(%S*)%s*$')
        -- local pc,hexa,opcode,args = s:sub(1,4),trim(s:sub(6,15)),s:sub(17,42):match('(%S+)%s+(%S*)%s*$')
         -- print(pc, hexa, opcode, args)
        if prev_hexa~='3B' and opcode then
            -- print(pc,hex,opcode,args)
            -- curr_pc, sig = tonumber(pc,16), hexa
			curr_pc, sig = tonumber(pc,16), hexa
            if jmp then mem:pc(jmp):r(curr_pc) jmp = nil end
				-- if pc~=jmp_skip then mem:pc(jmp):r(curr_pc) end
				-- jmp,jmp_skip = nil 
			-- end
            mem:pc(curr_pc):x(hexa,1)
			if REL_JMP[opcode] then sig, jmp, mem[curr_pc].rel_jmp = pc..':'..hexa, curr_pc, args end
            -- sig = REL_BRANCH[hexa] and pc..':'..hexa or hexa
            if nomem[sig] then
                mem:a(nomem[sig])
            else
                regs = s:sub(61,106)
                local f = DISPATCH[opcode] if f then f() else nomem[sig] = true end
                -- on ne connait le code asm vraiment qu'à la fin
                local asm, cycles =
                    args=='' and opcode or sprintf("%-4s %s", opcode, args),
                    "(" .. trim(s:sub(43,46)) .. ")"
                local equate = EQUATES:t(args:match('%$(%x%x%x%x)'), pc)
                if equate~='' then 
                    local equate_ptn = equate:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]','%%%1')
                    asm = asm:gsub(equate_ptn, '')
                end
                asm = sprintf("%-5s%s%s", cycles, asm, equate)
                if nomem[sig] then nomem[sig] = asm end
                mem:pc(curr_pc):a(asm)
            end
        end
		prev_hexa = hexa
    end
    f:close()
    out(string.rep(' ', 10) .. string.rep('\b',10))
    profile:_()
	
	-- nettoyage des branchements conditionnels non pris
	local last_bcc, last_arg
	for i=0,65535 do
		local m = mem[i]
		if m and m.asm then
			if m.r==last_bcc and i~=last_arg then
				m.r = NOADDR
			end
			if m.rel_jmp then
				last_bcc  = hex(i)
				last_arg  = tonumber(m.rel_jmp:match('%$(%x%x%x%x)'),16)
				m.rel_jmp = nil
			else
				last_bcc  = nil
				last_arg  = nil
			end
		end
	end
	
	local mb = size/1024/1024
    log('Analyzed %.3g Mb of trace (%.3g Mb/s).', mb, mb / (os.clock() -start_time))
end

-- essaye de deviner le type de machine en analysant la valeur de DP dans
-- la trace
local _guess_MACH = {MO=0,TO=0}
local function guess_MACH(TRACE)
    local THR = 100000
    log('Trying to determine machine.')
    profile:_()
    local f = assert(io.open(TRACE,'r'))
    for l in f:lines() do
        if     l:match('DP=[2A]') then _guess_MACH.MO = _guess_MACH.MO + 1 
        elseif l:match('DP=[6E]') then _guess_MACH.TO = _guess_MACH.TO + 1 end
        if _guess_MACH.MO + _guess_MACH.TO > THR then break end
    end
    f:close()
    profile:_()
    if _guess_MACH.MO + _guess_MACH.TO > THR then
        if _guess_MACH.MO > 2*_guess_MACH.TO then machMO(); EQUATES:ini() end
        if _guess_MACH.TO > 2*_guess_MACH.MO then machTO(); EQUATES:ini() end
    end
end

------------------------------------------------------------------------------
-- boucle principale (sortie par ctrl-c)
------------------------------------------------------------------------------
repeat
    -- attente de l'arrivée d'un fichier de trace
    wait_for_file(TRACE)
    
    -- essaye de déterminer le type de machine
    if OPT_MACH==MACH_XX then guess_MACH(TRACE) end 
    local _MIN,_MAX = OPT_MIN,OPT_MAX
    OPT_MIN = OPT_MIN or 0x0000
    OPT_MAX = OPT_MAX or 0xFFFF

    -- lecture fichier de trace
    read_trace(TRACE)
	
    -- écriture résultat TSV & html
    mem:save(newParallelWriter(
        newTSVWriter (assert(io.open(RESULT .. '.csv', 'w'))),
        OPT_HTML and newHtmlWriter(assert(io.open(RESULT .. '.html','w')), mem) or nil
    )):close()
    
    -- effacement fichier trace consomé
    if OPT_LOOP then log('Removing trace.'); assert(os.remove(TRACE)); log('Do it again...') end
    
    --  si le min/max n'est pas encore trouvé
    OPT_MIN,OPT_MAX = _MIN,_MAX
until not OPT_LOOP