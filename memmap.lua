-----------------------------------------------------------------------------
-- Tool    : memmap
-- Version : $Version$
-- Author  : Samuel Devulder
-- Date    : $Date$
--
-- Usage:
-- $Usage$ : see README
-----------------------------------------------------------------------------

local ARGV   = arg                     -- ligne de commande
local NOADDR = '----'                  -- marqueur d'absence
local NOCYCL = ''                      -- marqueur d'absence
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
local OPT_HOT     = false              -- hotspots ?
local OPT_HOT_COL = false              -- colored hotspots 
local OPT_MAP     = false              -- ajoute une version graphique de la map
local OPT_HTML    = false              -- produit une analyse html?
local OPT_SMOOTH  = "auto"             -- type de scroll html
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
                verbose(self.lvl, 'done (%.3gs).\n', time)
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
    return tostring(txt):match('^%s*(.*%S)')
end

-- memoization
local memoize = {
    -- version n->n
    ret_n = function(self, fcn)
        local size, cache, concat = 0,{},table.concat
        local info = debug.getinfo(fcn)
        if info.nparams==1 and not info.isvararg then
            return function(k)
                local v = cache[k]
                if v then
                    return unpack(v)
                else
                    v = {fcn(k)}
                    if size>=65536 then size,cache = 0,{} end
                    cache[k], size = v, size+1
                    return unpack(v)
                end
            end
        end
        return function(...)
            local k = concat(arg,'')
            local v = cache[k]
            if v then
                return unpack(v)
            else
                v = {fcn(...)}
                if size>=65536 then size,cache = 0,{} end
                cache[k], size = v, size+1
                return unpack(v)
            end
        end
    end,
    -- version n->1
    ret_1 = function(self, fcn)
        local size, cache, concat = 0,{},table.concat
        local info = debug.getinfo(fcn)
        if info.nparams==1 and not info.isvararg then
            return function(k)
                local v = cache[k]
                if v then
                    return v
                else
                    v = fcn(k)
                    if size>=65536 then size,cache = 0,{} end
                    cache[k], size = v, size+1
                    return v
                end
            end
        end
        if info.nparams==2 and not info.isvararg then
            size = -65535
            -- do local function set(k, v)
                -- size = size+1
                -- if size>0 then size,cache = -65535,{} end
                -- cache[k] = v
                -- return v
            -- end
            -- return function(a1,a2)
                -- local k = a1..a2
                -- return cache[k] or set(k,fcn(a1,a2))
            -- end end
            -- do return function(a1,a2)
                -- local k = a1..a2
                -- local v = cache[k]
                -- if v then
                    -- return v
                -- else
                    -- size,v = size+1,fcn(a1,a2)
                    -- if size>0 then size,cache = -65535,{} end
                    -- cache[k] = v
                    -- return v
                -- end
            -- end end
            local VOID={}
            return function(a1,a2)
                local k = cache[a1]; if not k then k={}; cache[a1] = k end
                local v = k[a2]
                if v then
                    return v~=VOID and v or nil
                else
                    size,v = size+1,fcn(a1,a2)
                    if size>0 then size,cache,k = -65535,{},{}; cache[a1]=k end
                    k[a2] = v or VOID
                    return v
                end
            end
        end
        size = -65535
        return function(...)
            local function f(x, ...) return x and x..f(...) or '' end
            local k = f(...)
            local v = cache[k]
            if v then
                return v
            else
                size,v = size+1,fcn(...)
                if size>0 then size,cache = -65535,{} end
                cache[k] = v
                return v
            end
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
        if short and l=='' then empty = empty + 1; if empty==2 then break end end
        if l then io.stdout:write(l .. '\n') end
    end
    f:close()
    os.exit(errocode or 5)
end

-- utilitaires fichiers
local function exists(file)
   local ok, err, code = file and os.rename(file, file)
   if not ok then
      if code == 13 then
         -- Permission denied, but it exists
         return true
      end
      local f = io.open(file,'r')
	  if f then f:close() ok,err=true end
   end
-- print('EXIST',file,ok,err,code)
   return ok, err
end
local function isdir(file)
	if file=='.' then return true end
	file = file..'/'
	return exists(file) or exists(file:gsub('/','\\'))
end
local function isfile(file)
   local f = io.open(file,'r')
   if f then f:close() return true else return false end
end
local function dir(folder)
	local ret = {}
	if isdir(folder) then
		for _,cmd in ipairs{
			'DIR 2>NUL /B "'..folder:gsub('\\','/'):gsub('/','\\\\')..'"',
			"find -maxdepth 1 -print0 '"..folder.."'",
			"ls '"..folder.."'",
			nil} do
			local f = io.popen(cmd)
			if f then
				for entry in f:lines() do 
					if not entry:match('^%.') then
						table.insert(ret, entry) 
					end
				end
				f:close()
				break
			end
		end
	end
	return ret
end

------------------------------------------------------------------------------
-- Analyse la ligne de commande
------------------------------------------------------------------------------

local function machTO()
    OPT_MACH,OPT_MIN,OPT_MAX = MACH_TO,OPT_MIN or 0x6100,OPT_MAX or 0xDFFF
    log("Set machine to %s", OPT_MACH)
end
local function machMO()
    OPT_MACH,OPT_MIN,OPT_MAX = MACH_MO,OPT_MIN or 0x2100,OPT_MAX or 0x9FFF
    log("Set machine to %s", OPT_MACH)
end

for i,v in ipairs(ARGV) do local t
    v = v:lower()
    if v=='-h'
    or v=='?'
    or v=='--help'   then usage()
    elseif v=='-loop'    then OPT_LOOP    = true
    elseif v=='-html'    then OPT_HTML    = true
    elseif v=='-smooth'  then OPT_SMOOTH  = "smooth"
    elseif v=='-reset'   then OPT_RESET   = true
    elseif v=='-map'     then OPT_MAP     = true
    elseif v=='-hot'     then OPT_HOT     = true
    elseif v=='-hot=col' then OPT_HOT     = true; OPT_HOT_COL = true
    elseif v=='-equ'     then OPT_EQU     = true
    elseif v=='-verbose' then OPT_VERBOSE = 1
    elseif v=='-mach=??' then OPT_MACH    = MACH_XX; OPT_EQU  = true
    elseif v=='-mach=to' then machTO()
    elseif v=='-mach=mo' then machMO()
	else t=v:match('%-trace=(%S+)')    if t then TRACE       = t
    else t=v:match('%-equ=(%S+)')      if t then OPT_EQU     = t																
    else t=v:match('%-from=(-?%x+)')   if t then OPT_MIN     = (tonumber(t,16)+65536)%65536
    else t=v:match('%-to=(-?%x+)')     if t then OPT_MAX     = (tonumber(t,16)+65536)%65536
    else t=v:match('%-map=(%d+)')      if t then OPT_COLS    = tonumber(t)
    else t=v:match('%-verbose=(%d+)')  if t then OPT_VERBOSE = tonumber(t)
    else io.stdout:write('Unknown option: ' .. v .. '\n\n'); usage(21, true)
    end end end end end end end
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
            self[self._page .. addr] = (type(OPT_EQU)=='boolean' and (OPT_MACH==nil or OPT_MACH==MACH_XX) and self._mach or '') .. name
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
        or   '') or ''
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
	readASM6809_lst = function(self, file, single)
        -- ASM6809 output of ugbasic
		file = file or 'main.lst'
        f = io.open(file,'r')
        if f then local prof
            for l in f:lines() do
                local a,lbl = l:match('(%x+)                  (%S+)')
                if lbl then 
					if not prof then prof = true profile:_('Reading ASM6809 symbols from ' .. file) end
					self:d(a,lbl) 
				end
            end
            f:close()
			if prof then profile:_() end
        end
	end,
	readLWASM_txt = function(self, file, single)
		file = file or 'main.txt'
		f = io.open(file,'r')
		if f then local prof
			for l in f:lines() do
                local a,b,lbl = l:match('(%x%x%x%x)                  %(%s*(%S+)%):%d+%s+(%S+):')
                if lbl then 
					if not prof then prof = true profile:_('Reading LWASM symbols from ' .. file) end
					self:d(a,(not file or single) and lbl or b..':'..lbl) 
				end	
            end
			f:close()
			if prof then profile:_() end
		end
	end,
	readLWASM_lwmap = function(self, file, single)
		file = file  or 'main.lwmap'
		f = io.open(file,'r')
		if f then local prof
            for l in f:lines() do
                local lbl,b,a = l:match('Symbol: (%S+) %((.*)%) = (%x%x%x%x)')
                if a then 
					if not prof then prof = true profile:_('Reading LWASM symbols from ' .. file) end
					self:d(a, (not file or single) and lbl or b..':'..lbl) 
				end	
            end
			f:close()
			if prof then profile:_() end
		end
	end,
	readC6809_lst = function(self, file, single)
		file = file or 'codes.lst'
        local f = io.open(file,'r')
        if f then local prof
			for l in f:lines() do
                local a,lbl = l:match('%s+%d+x%s+Label%s+(%x+)%s+(%S+)%s*')
                if lbl then 
					if not prof then prof = true profile:_('Reading C6809 symbols from ' .. file) end
					self:d(a,lbl) 
				end
            end
            f:close()
			if prof then profile:_() end
        end
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
           'FFF0','VEC.RSVD')
        local setMO = set{MACH_XX, MACH_MO}
        local setTO = set{MACH_XX, MACH_TO}
        if setMO[OPT_MACH or MACH_XX] then self:iniMO() end
        if setTO[OPT_MACH or MACH_XX] then self:iniTO() end
		if OPT_EQU==true then
			self:readC6809_lst()
			self:readASM6809_lst()
			self:readLWASM_txt()
			self:readLWASM_lwmap()
		end
		if type(OPT_EQU)=='string' then
			local files = {}
			local function collect(entry)
				if isdir(entry) then
					for _,e in ipairs(dir(entry)) do collect(entry..'/'..e) end
				elseif isfile(entry) then
					table.insert(files, entry)
				else
					-- print('ignored', entry)
				end
			end
			for entry in string.gmatch(OPT_EQU, '%s*([^,]+)%s*') do
				collect(entry)
			end
			local single = files[2]==nil
			for _,file in ipairs(files) do
				if file:match("%.lst$")       then self:readASM6809_lst (file, single) end
				if file:match("%.txt$")       then self:readLWASM_txt   (file, single) end
				if file:match("%.lwmap$")     then self:readLWASM_lwmap (file, single) end
				if file:match("/codes%.lst$") then self:readC6809_lst   (file, single) end
			end
		end
    end,
nil} EQUATES:ini()

------------------------------------------------------------------------------
-- différent formateurs de résultat
------------------------------------------------------------------------------

-- Writer de base
local function newBasicWriter()
    local function not_implemented() error('not implemented!') end
    return {
        close  = not_implemented,
        printf = not_implemented,
        id     = not_implemented,
        title  = not_implemented,
        header = not_implemented,
        row    = not_implemented,
        footer = not_implemented,
    nil}
end

-- Writer Parallèle
local function newParallelWriter(...)
    log('Created Parallel writer.')
    local w = newBasicWriter();
    w.writers = {...}
    function w:_dispatch(fcn, ...)
        for _,w in ipairs(self.writers) do
            local f = w[fcn];
            f(w,...)
        end
    end
    function w:close (...) self:_dispatch('close',  ...) end
    function w:printf(...) self:_dispatch('printf', ...) end
    function w:id    (...) self:_dispatch('id',     ...) end
    function w:title (...) self:_dispatch('title',  ...) end
    function w:header(...) self:_dispatch('header', ...) end
    function w:row   (...) self:_dispatch('row',    ...) end
    function w:footer(...) self:_dispatch('footer', ...) end
    return w
end

-- Writer TSV (CSV avec des TAB(ulations))
local function newTSVWriter(file, tablen)
    tablen = tablen or 8
    local function align(n)
        return tablen*math.floor(1+n/tablen)
    end
    local w = newBasicWriter();
    -- evite le fichier vide
    w.file = file or {write=function() end, close=function() end}
    w.file:write('sep=\\t\t(use a tabulation of '..tablen..')\n\n')

    function w:close()
        self.file:write("End of file\n")
        self.file:close()
    end
    function w:printf(...)
        self.file:write(sprintf(...))
    end
    function w:id() end
    function w:title(...)
        local txt = sprintf(...) .. ':'
        self:printf("%s\n%s\n", txt, string.rep('~', txt:len()))
    end
    function w:header(columns)
        local empty = true
        self.align = {}
        self.ncols = #columns
        self.clen = {}
        self.hsep = ''
        cols = {}
        for i,n in ipairs(columns) do
            local tag,fnt,txt = n:match('^([<=>]?)([%*]?)(.*)')
            self.align[i], cols[i], self.clen[i] = tag=='' and '<' or tag, txt, 0
            if empty and trim(txt) then empty = false end
        end
        if not empty then
            self:row(cols)
            local l=0 for _,k in ipairs(self.clen) do l = l + k end
            self.hsep = string.rep('=', l-1) .. '\n'
            self.file:write(self.hsep)
        end
    end
    function w:footer()
        self.file:write(self.hsep .. '\n')
    end
    function w:row(cels)
        local t, ok = '', #cels==self.ncols
        for i,n in ipairs(cels) do
            t = t .. '\t'
            n = tostring(n)

            if i==7 then
                local addr = n:match('%$(%x%x%x%x)')
                local equate = addr and EQUATES:t(addr) or ''
                n = n .. equate
            end

            if ok and n:len()>self.clen[i] then self.clen[i] = align(n:len()) end
            n = trim(n) or ''
            if self.align[i]=='>' then
                t = t .. string.rep(' ', self.clen[i] - n:len() - 1) .. n
            elseif self.align[i]=='=' then
                t = t .. string.rep(' ',math.floor((self.clen[i] - n:len() - 1)/2)) .. n
            else
                t = t .. n .. string.rep(' ', self.clen[i] - n:len() - tablen)
            end
        end
		t = t:gsub('\n','\\n')
        self:printf('%s\n', t=='' and t or t:sub(2))
    end
    log('Created CSV writer (tab=%d).', tablen)
    return w
end

-- Writer OPT_HTML (quelle horreur!)
local function newHtmlWriter(file, mem)
    -- récup des adresses utiles
    local valid = {}
    for i=OPT_MIN,OPT_MAX do
        local m = mem[i]
        if m and (m.asm or m.r~=NOADDR or m.w~=NOADDR) then valid[hex(i)] = true end
    end

    -- liens code --> mémoire
    local code2mem = {}
    for i=OPT_MAX,OPT_MIN,-1 do -- du haut vers le bas pour ne garder que le 1er accès
        local m = mem[i]
        if m and not m.s then
            i = hex(i)
            if m.w~=NOADDR and valid[m.w] then code2mem[m.w] = i end
            -- le read a priorité sur le write
            if m.r~=NOADDR and valid[m.r] then code2mem[m.r] = i end
        end
    end

    -- descrit le contenu d'une adresse
    local function describe(addr, opt_last, opt_from)
        local function code(kind, where)
            if where~=NOADDR then
                local i = tonumber(where,16)
                local m = mem[i]
                return m and m.asm and kind .. m.asm:gsub('%s+',' ') .. ' (from $' .. where .. ')' or ''
            else
                return ''
            end
        end
        local m = mem[tonumber(addr,16)]
        if m then
            local RWX = mem:RWX(m)
            local opt_asm_addr, opt_asm = m.x>0 and addr, m.asm
            -- on utilise opt_last si l'adresse n'est pas pile sur le début de l'instruction
            if opt_asm_addr and not opt_asm and opt_last then opt_asm_addr, opt_asm = hex(opt_last), mem[opt_last].asm end
            --
            local anchor = ''
            if opt_asm_addr and (RWX=='X--' or (RWX=='XR-' and m.asm)) then anchor = opt_asm_addr
            elseif RWX=='-RW' and m.r==m.w      then anchor = m.r
            elseif RWX=='-R-' and m.r~=opt_from then anchor = m.r
            elseif RWX=='--W' and m.w~=opt_from then anchor = m.w
            elseif RWX=='-RW' and m.r==opt_from then anchor = m.w
            elseif RWX=='-RW' and m.w==opt_from then anchor = m.r end
            anchor = valid[anchor] and anchor or addr
            --
            local equate = EQUATES:t(addr)
            local equate_ptn = equate:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]','%%%1')
            local title  = '$' .. addr .. ' : ' .. RWX .. equate ..
                           (opt_asm and '\nX = ' .. opt_asm:gsub(equate_ptn,'') or '') ..
                           code('\nR = ', m.r):gsub(equate_ptn,'')..
                           code('\nW = ',  m.w):gsub(equate_ptn,'')

            -- if m.r~=m.w then title = title .. code(m.w):gsub(equate_ptn,'') end

            return title, RWX, anchor
        else
            return '$' .. addr .. ' : untouched' .. EQUATES:t(addr), '---', addr
        end
    end

    -- échappement html
    local function esc(txt)
        local r = txt
        -- :gsub("<<","&laquo;")
        :gsub('['..[['"<>&]]..']', {
            ["'"] = "&#39",
            ['"'] = "&quot;",
            ["<"]="&lt;",
            [">"]="&gt;",
            ["&"]="&amp;"})
        :gsub("&lt;%-", "&larr;"):gsub("%-&gt;", "&rarr;")
        :gsub('\n','<BR>\n')
        :gsub('  ',' &nbsp;')
        return r
    end

    -- pointe sur l'adrese la plus proche
    local function closest_ahref(addr)
        if valid[addr] then
            return '<a href="#fm' .. addr .. '">' .. addr .. '</a>'
        else
            local base,n = tonumber(addr,16)
            for i=1,65535 do
                n = hex(base+i); if valid[n] then break end
                n = hex(base-i); if valid[n] then break end
            end
            if valid[n] then
                return '<a href="#fm' .. n .. '" title="goto $' .. n ..'">' .. addr .. '</a>'
            else
                return add
            end
        end
    end

    -- retourne le code html pour un hyperlien sur "addr" avec le texte
    -- "txt" (le tout pour l'adresse "from")
    local function ahref(from, addr, txt)
        local title, RWX, anchor = describe(addr,nil,from)
        -- ajoute des petites flèches pour dire où va le lien par
        -- rapport à l'adresse courante
        local function esc2(title)
            local x = esc(title)
            if mem[tonumber(from,16) or ''] and addr and addr~=from then
                local arr = '&' .. (addr <= from and 'u' or 'd') .. 'arr;'
                x = x:gsub(':', arr .. arr, 1)
            end
            return x
        end
        --if OPT_EQU and EQUATES[txt] then txt = EQUATES[txt] end
        return valid[anchor]
        and '<a href="#fm' .. anchor .. '" title="' .. esc2(title):gsub('<BR>','') .. '">' .. esc(txt) .. '</a>'
        or esc(txt)
    end

    -- allez, on crée le writer
    local w = newBasicWriter()

    -- evite les fichier nil
    w.file=file or {write=function() end, close=function() end}

    -- pour les title
    w.HEADING = "h1"
    w.HEXADDR = '([0123456789ABCDEF][0123456789ABCDEF][0123456789ABCDEF][0123456789ABCDEF])'

    -- gestion du body
    w._body_ = {}
    function w:_body(...)
        for _,v in ipairs{...} do
            table.insert(self._body_, tostring(v))
        end
    end

    -- gestion du style
    w._style_ = ''
    function w:_style(...)
        for _,v in ipairs{...} do
            self._style_ = self._style_ .. tostring(v)
        end
    end

    -- les trucs simples
    function w:printf(...)
        local txt = sprintf(...)
        self:_body(esc(txt))
    end

    function w:row(cels)
        self:_row('td', cels)
    end

    -- gestion des id
    w._2panes = nil
    function w:id(id)
        self._id = {id=id, no=-1}
        if self._2panes==nil then
            if id=='hotspots'     then self._2panes = 1 end
            if id:match('memmap') then self._2panes = 1 end
        end
        if self._2panes==1 then
            self._2panes = true
            self:_body('  </div><div id="right">\n')
        end
    end
    w:id('DEFAULT_ID')
    function w:_nxId()
        self._id.no = self._id.no + 1
        return self._id.no==0 and self._id.id
                              or  self._id.id .. '_' .. self._id.no,
               self._id.no==0
    end

    -- le titre
    function w:title(...)
        local txt = sprintf(...)
        self:_body('<',self.HEADING,' id="', self:_nxId(), '">',
                    esc(txt):gsub('%$'..self.HEXADDR, function(a) return "$" .. closest_ahref(a) end),
                   '</',self.HEADING,'>','\n')
    end

    -- fin de table
    function w:footer()
        self:_body('  </table>\n')
        if self._footer_callback then
            self._footer_callback(self)
            self._footer_callback = nil
        end
    end

    -- début de table
    function w:header(columns)
        local id = self:_nxId()

        -- selection de la fonction de gestion des lignes en fonction de l'id
        self._row = self._std_row
        if id:match('flatmap')  then self._row = self._flatmap_row end
        if id:match('hotspots') then self._row = self._hotspot_row end
        if id:match('memmap')   then self._row = self._memmap_row  end
        if id:match('caption')  then self._row = self._caption_row end

        self.ncols = #columns
        -- gestion du style
        local align  = {[''] = 'left', ['<'] = 'left', ['='] = 'center', ['>'] = 'right'}
        local family = {['*'] = 'bold'}
        local cols, empty = {}, true
        for i,n in ipairs(columns) do
            local tag,font,txt = n:match('^([<=>]?)([%*]?)(.*)')
            cols[i] = trim(txt)
            if cols[i] then empty=false else cols[i]='' end
            self:_style('    #', id, ' td:nth-of-type(', i, ') {\n', family[font] and
                        '      font-weight:' .. family[font]..';\n' or '',
                        '      text-align: ', align[tag], ';\n',
                        '    }\n')
        end

        local class = ""
        if id:match('memmap') then
            class = ' class="memmap"'
            self._footer_callback = function(self)
                self:_body('  <script>document.getElementById("',id,'").style.display = "table";</script>\n')
            end
        -- elseif id:match('caption') then
            -- self:_body('<noscript>\n')
            -- self._footer_callback = function(self) self:_body('</noscript>\n') end
        else
			self:_body('  <div style="display:flex">\n')
            self._footer_callback = function(self)
				if id:match('hotspots') then
					self:_hotspot_footer()
				end
			    self:_body('  </div>\n')
            end
        end

        self:_body('  <table id="',id,'"', class ,'>\n')
        if not empty then self:_std_row("th", cols) end
    end

    -- fonction de fermeture. C'est ici qu'on écrit vraiment dans
    -- le fichier après avoir collecté toutes les infos de style.
    -- on en profite aussi pour ajouter les information de progression
    -- du chargment maintenant que l'on connait l'ensemble du corp
    -- du fichier HTML.
    function w:close()
        local function f(v, ...)
            if v then self.file:write(tostring(v)) f(...) end
        end
        f([[<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>DCMoto_MemMap</title>
  <style>
    body {
      scroll-padding-top:    3em;
      scroll-padding-bottom: 4em;
      scroll-behavior:       ]], OPT_SMOOTH, ';\n',
    self._2panes and [[

      /* 2 columns */
      overflow: hidden;
      margin: 0;
      display:flex;
      flex-flow:row;]]..'\n' or '', [[
    }

    #left {
      overflow: auto;
      width:    auto;
      height:   100vh;

      scroll-padding-top:    3em;
      scroll-padding-bottom: 4em;
      scroll-behavior:       ]], OPT_SMOOTH, ';\n',[[
    }

    #right {
      flex-grow: 1;

      overflow:  auto;
      height:    100vh;

      display:   flex;
      flex-flow: column;

      scroll-padding-top:    3em;
      scroll-padding-bottom: 4em;
      scroll-behavior:       ]], OPT_SMOOTH, ';\n',[[
    }

    /* trucs globaux: liens */
    :target {
      background-color: gold;
    }
    a {
      font-weight:     bold;
      text-decoration: none;
    }
    a:hover {
      background-color: yellow;
      text-decoration:  underline;
    }
    a:active {
       background-color :gold;
    }

    /* trucs globaux: table */
    table {
      border-collapse: collapse;
      border-top:      1px solid #ddd;
      border-bottom:   1px solid #ddd;
      font-family:     monospace;
    }
    th, td {
      padding-left:  8px;
      padding-right: 8px;
      border-left:   1px solid #ddd;
      border-right:  1px solid #ddd;
    }
    th {
      background-color: lightgray;
      border-bottom:    1px solid #ddd;
    }
    tr {
      height: 1em;
    }
    table tr:hover {
      background-color: lightgray;
    }

    /* trucs globaux: couleurs */
    .c0 {background-color:#111;}
    .c1 {background-color:#e11;}
    .c2 {background-color:#1e1;}
    .c3 {background-color:#fe1;}
    .c4 {background-color:#11e;}
    .c5 {background-color:#e1e;}
    .c6 {background-color:#1ee;}
    .c7 {background-color:#eee;}

    /* loading screen */
    #loadingPage {
      position:        fixed; top: 0; left: 0; width: 100%; height: 100%;
      display:         none;
      justify-content: center;
      align-items:     center;
    }
    #loadingGray {
      position:         fixed; top: 0; left:0; width:100%; height: 100%;
      cursor:           wait;
      background-color: black;
      opacity:          0.5;
      z-index:          99;
    }
    #loadingProgress {
      display:          block;
      padding:          0.6em;
      cursor: progress;
      background-color: #fefefe;
      color:            black;
      font-size:        2em;
      font-weight:      bold;
      z-index:          100;
    }
    #loadingProgress:hover {
      background-color: #fefefe;
    }

    /* les tables memmap */
    .memmap {
      display:      none;
      table-layout: fixed;
    }
    .memmap a {
      display:         block;
      height:          100%;
      width:           100%;
      text-decoration: none;
      cursor:          default;
    }
    .memmap tr            {height: inherit;}
    .memmap a:hover       {text-decoration:  none;}
    .memmap td.c7         {cursor: not-allowed}
    .memmap td.c0>a:hover {background-color:white;}
    .memmap td.c1>a:hover {background-color:black;}
    .memmap td.c2>a:hover {background-color:black;}
    .memmap td.c3>a:hover {background-color:black;}
    .memmap td.c4>a:hover {background-color:white;}
    .memmap td.c5>a:hover {background-color:black;}
    .memmap td.c6>a:hover {background-color:black;}
    .memmap td.c7>a:hover {background-color:black;}
    .memmap td {
      padding:    0;
      border:     1px solid #ddd;
      min-width:  2px;
      min-height: 2px;
]],
'      width:      ', 100/OPT_COLS, 'vmin;\n',
'      height:     ', 100/OPT_COLS, 'vmin;\n',
'    }\n', self._style_, [[
    .caption {
        align:   center;
        display: inline-block;
        width:   1em;
        height:  1em;
    }
    @media (prefers-color-scheme: dark) {
      body {
        background-color: #1c1c1e;
        color: #fefefe;
      }
      :target          {background-color: #b70; color: black;}
      a                {color: #6fb9ee;}
      a:hover          {background-color: gold;}
      table th,
      table tr:hover   {background-color: #777; color: black;}
      .c0              {background-color: #111;}
      .c1              {background-color: #c11;}
      .c2              {background-color: #1c1;}
      .c3              {background-color: #cc1;}
      .c4              {background-color: #11c;}
      .c5              {background-color: #c1c;}
      .c6              {background-color: #1cc;}
      .c7              {background-color: #ccc;}
      #loadingProgress {background-color: lightgray;}
    }

    @media (prefers-reduced-motion: reduce) {
      html             {scroll-behavior: auto;}
    }
  </style>
</head>
<body onhashchange="locationHashChanged()">
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
    on('mouseover', window.matchMedia('(prefers-color-scheme: dark)').matches ? 'gold' : 'yellow');
    on('mouseout',  null);
    function hideLoadingPage() {
        const loading = document.getElementById("loadingPage");
        if(loading !== null) {
            loading.style.display = "none";
            document.body.removeChild(loading);
        }
    }
    function progress(percent) {
      const e = document.getElementById('loadingProgressBar')
      if(e !== null) e.value = percent;
    }
    function locationHashChanged(event)  {
        const location = document.location;
        const elt = document.getElementById(location.hash.substring(1));
        if(elt!==null) elt.scrollIntoView({
            behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : ']],OPT_SMOOTH,[[',
            block: 'nearest',
        });
    }
	function hs(id, no) {
		const e = document.getElementById(id)
		if(e !== null) {
			e.className += " hs" + no;
			e.title      = "Hot spot #" + no;
		}
    }
  </script>
  <div id="loadingPage">
    <div id="loadingGray"></div>
    <button id="loadingProgress" onclick="hideLoadingPage()" title="click to access anyway" class="h1">
        Please wait while loading...<br>
        <progress id="loadingProgressBar" max="1"></progress>
    </button>
  </div>
  <script>
    progress(0);
    document.getElementById('loadingPage').style.display = 'flex';
    window.addEventListener("load", hideLoadingPage);
  </script>
]])

        if self._2panes then f('  <div id="left">\n') end

        -- écriture du body avec la progression
        local nxt, size = 0, #self._body_
        for i,txt in ipairs(self._body_) do
            f(txt)
            if txt:len()>0 and txt:sub(-1)=='\n' and i>nxt then
                f('<script>progress(', (i-1)/size, ')</script>\n')
                nxt = i + size/100 -- on augmente de 1%
            end
        end

        if self._2panes then f('  </div>') end
        f[[
</body>
</html>]]
        self.file:close()
    end

    -- lignes html pure
    function w:_raw_row(tag, html_cols, extra)
        if nil==html_cols[1] then
            html_cols[1] = '&nbsp;'
        end

        local tr = {}
        local function add(v,...)
            if v then table.insert(tr,v) add(...) end
        end
        add('    ','<tr')
        local id,orig = self:_nxId()
        if orig then add(' id="',id,'"') end
		if extra then add(' ',extra) end
        add('>')

        local span = #html_cols~=self.ncols and #html_cols or -1
        for i,v in ipairs(html_cols) do
            add('<', tag)
            if i==span then add(' style="text-align:left;" colspan="', self.ncols - i + 1,'"') end
            add('>', v, '</',tag,'>')
        end
        add('</tr>\n')
        self:_body(unpack(tr))
    end

    -- ligne standard
    function w:_std_row(tag, columns)
        local cols, patt = {}, '(.*%$)'..self.HEXADDR..'(.*)'
        for i,v in ipairs(columns) do
            local t = esc(trim(v) or ' ')
            local before,a,after = t:match(patt)
            if a then
                t = before .. closest_ahref(a) .. after
            end
            cols[i] = t
        end
        self:_raw_row(tag,cols)
    end

    -- ligne de la flatmap
    function w:_flatmap_row(tag,columns)
        local ADDR, cols = columns[1], {}
        -- la 1er colonne donne l'id
        if ADDR and ADDR:len()==4 then self:id('fm'..ADDR) end
        for i,v in ipairs(columns) do
            v = trim(tostring(v)) or ' '
            if i==2 or i==3 then
                v = ahref(ADDR,v,v)
            elseif i==7 then
                local back = code2mem[ADDR]
                if back then
                    local before,arg,after = v:match('(.*%$)'..self.HEXADDR..'(.*)')
                    if arg and OPT_EQU and EQUATES[arg] then
                        if valid[arg] then before, arg = before:sub(1,-2), EQUATES[arg]
                        else after = EQUATES:t(arg) .. after end
                    end
                    if not arg then before,arg,after = v:match('^(%S+%s+[%[<]?)(%-?%$?[%w_,+-]+)(.*)$') end
                    if not arg then before,arg,after = v:match('^(%s*)([%w_,+-]+)(.*)$') end
                    if not arg then error(v) end
                    v = esc(before) .. ahref(ADDR, back, arg) .. esc(after)
                else
                    -- sauts divers
                    local before,addr,after = v:match('^(.*%$)'..self.HEXADDR..'(.*)$')
                    local arg = addr
                    if arg and OPT_EQU and EQUATES[arg] then
                        if valid[arg] then before, arg = before:sub(1,-2), EQUATES[arg]
                        else after = EQUATES:t(arg) .. after end
                    end
                    if addr then
                        v = esc(before) .. ahref(ADDR, addr, arg) .. esc(after)
                    else
                        v = esc(v)
                    end
                end
            else
                v = esc(v)
            end
            cols[i] = v
        end
        self:_raw_row(tag,cols)
    end

    -- ligne hotspot
    function w:_hotspot_row(tag,columns)
		if OPT_HOT_COL then
			local function rgb_style(id)
				self._hotspot_row_ids = self._hotspot_row_ids or {}
				self._hotspot_row_ids[id] = self._hotspot_row_no
			end
			local ADDR,no = trim(columns[2]),columns[1]:match('#(%d+)')
			if no then
				local rgb = {math.random(),math.random(),math.random()}
				local max = math.max(unpack(rgb))
				for i=1,3 do rgb[i] = math.floor(8+7*rgb[i]/max) end
				self._hotspot_row_no  = no
				self._hotspot_row_adr = nil
				self:_style('	.hs',no,  ':target {background-color : gold;}\n')
				self:_style('	.hs',no,  '        {background-color : ',string.format('#%03x',rgb[1]+rgb[2]*16+rgb[3]*256),';}\n')			
			end
			if ADDR and ADDR:len()==4 then 
				if ADDR ~= "...." then
					if self._hotspot_row_adr0 then
						for i=self._hotspot_row_adr0+1,tonumber(ADDR,16)-1 do
							rgb_style(string.format("fm%04X",i))
						end
						self._hotspot_row_adr0 = nil
					end
					rgb_style('hs'..ADDR)
					rgb_style('fm'..ADDR)
					self:id('hs'..ADDR) 
					self._hotspot_row_adr = ADDR
				else
					ADDR = self._hotspot_row_adr
					self._hotspot_row_adr0 = tonumber(ADDR,16)
					rgb_style('hs_'..ADDR)
					self:id('hs_'..ADDR) 
				end
			else
				self._hotspot_row_adr = nil
				self._hotspot_row_no  = nil
			end
		end
		
        local cols = {}
        for i,v in ipairs(columns) do
            v = trim(v) or ''
            if i==2 then
                v = ahref('',v,v)
            else
                v = esc(v)
            end
            cols[i] = v
        end
        self:_raw_row(tag,cols,self._hotspot_row_extra)
    end
    function w:_hotspot_footer()
		if self._hotspot_row_ids then
			local t,n = '	<script>\n\t\t',-1
			for id,no in pairs(self._hotspot_row_ids) do
				n = n+1 if n==5 then n,t=0,t..'\n\t\t' end
				t = t..'hs("'..id..'",'..no..'); '
			end
			self:_body(t..'\n	</script>\n')
			self._hotspot_row_ids = nil
		end
	end

    -- TODO ligne memmap
    w._memmap_color = {
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
    function w:_memmap_row(tag,cols)
        local t = {} local function add(v,...)
            if v then self:_body(v) add(...) end
        end
        add('<tr>')
        local BASE = tonumber(cols[1],16)-1
        for i=1,cols[2]:len() do
            local m,a = mem[BASE+i],hex(BASE+i)
            if m then
                local title, RWX, anchor = describe(a, self._memmap_last_asm_addr)
                if m.asm then self._memmap_last_asm_addr = BASE+i end
                add('<td', ' class="c', self._memmap_color[RWX],'"', ' title="', esc(title):gsub('<BR>',''), '">',
                    '<a href="#fm', m.x>0 and hex(self._memmap_last_asm_addr) or a, '"><noscript>',cols[2]:sub(i,i),'</noscript></a>')
            else
                add('<td class="c7" title="$', a, esc(EQUATES:t(a)),' : ---"><noscript>-</noscript></td>')
            end
        end
        add('</tr>\n')
    end

    function w:_caption_row(tag,columns)
        local cols = {}
        for i,v in ipairs(columns) do
            v = trim(v) or ' '
            if i==2 then
                local c = self._memmap_color[trim(columns[1])]
                local d = (c==0 or c==4) and "white" or "black";
                v = '<span class="caption c' .. c ..
                    '" style="color: ' .. d .. ';">' ..
                    '<noscript>' .. esc(v) .. '</noscript>' ..
                    '</span>'
            else
                v = esc(v)
            end
            cols[i] = v
        end
        self:_raw_row(tag,cols)
    end

    log('Created HTML writer.')
    return w
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
    local function newHot()
        return {
            x = 0,                         -- count
			t = 0,                         -- cycles
			a = nil,                       -- start address (hex)
			z = nil,                       -- end adress (dec, exclusive)
			j = nil,                       -- jmp addr (hex)
			b = nil,                       -- cond addr (hex)
			p = {},                        -- trace (hex or -1)
            add = function(self,i,m)
				if not m.asm then return self end
				if not m.cycles then error(m.asm) end
				if not self.a then self.a = hex(i) end
				self.z = i + m.hex:len()/2
                self.x = m.x
                self.t = self.t + self.x * (tonumber(m.cycles) or 5) -- 5 because of long jump
                self.i = i -- dernière adresse du bloc
				table.insert(self.p, hex(i))
				-- if #self.p==4 then self.p[2] = -1 table.remove(self.p,3) end
				return self
            end,
            push = function(self, spots)
				local mem = mem[self.i]
                local asm = mem.asm
                local jmp,addr = asm:match('(%a+)%s+%$(%x%x%x%x)')
				if not addr then
					jmp,addr = asm:match('(%a+)%s+<%$(%x%x)')
					if jmp and addr then 
						addr = mem.dp .. addr
					elseif asm:match('RTS$') or asm:match('RTI$') or asm:match('PC$') then
						jmp,addr = 'JMP','----'
					end
				end
				self.z,self.i = hex(self.z) -- adresse block suivant
				self.j = self.z
			    if addr then
                    if jmp=='JMP' or jmp=='BRA' or jmp=='LBRA' then
                        self.j = addr
                    elseif REL_JMP[jmp] then
                        self.b = addr
                    end
                end
                spots[self.a] = self
                return nil
            end,
			merge = function(self, other)
				-- simple
				-- for _,p in ipairs(other.p) do table.insert(self.p, p) end
				
				-- si other suit direct self, alors on reduit la TRACE
				for _,p in ipairs(other.p) do table.insert(self.p, p) end
				
				-- out('merge %s-%s and %s-%s\n', self.a, self.z, other.a, other.z)
				self.t = self.t + other.t
				self.x = math.max(self.x, other.x)
				self.z = other.z
				self.j = other.j
				self.b = other.b
				other.merged = true
			end,
			compressTrace = function(self)
				local toKeep = {}
				for _,a in ipairs(self.p) do
					local m = mem[tonumber(a,16)]
					if m.asm then
						local b = m.asm:match('%s%$(%x%x%x%x)$')
						if b and b<=a then toKeep[b] = true end
					end
				end
			
				local i,j,a,m = 1
				function nxt(a)
					a = tonumber(a,16)
					return hex(a + mem[a].hex:len()/2)
				end
				while self.p[i] do 
					j,a = i+1,nxt(self.p[i])
					while not toKeep[a] and a==self.p[j] do j,a = j+1,nxt(self.p[j]) end
					if j-i>=4 then -- compress
						repeat
							j=j-1
							table.remove(self.p, j-1)
						until j-i<4
						self.p[i+1] = -1
					end
					i = j
				end
				return self
			end
        }
    end
	
    -- construit les sections continues
	local BARIER = set{'JMP','BRA','LBRA','RTS','RTI'}
	for i=OPT_MIN,OPT_MAX do if mem[i] and mem[i].asm then
        local m = mem[i]
		-- if hot and (m.r~=NOADDR or hot.z~=i) then hot = hot:push(spots) end -- jumped-in
		-- if hot==nil then 
			-- if m.x>0 then hot = newHot():add(i,m) end
		-- else
			-- hot:add(i,m)
			-- decide end of block
			-- local op = m.asm:match('^(%a+)')
			-- if REL_JMP[op] or BARIER[op] or m.asm:match('PC$') then
				-- hot = hot:push(spots)
			-- end
		-- end
		if hot and hot.x~=m.x then hot = hot:push(spots) end
		if hot and m.x==hot.x then hot:add(i,m)
			local op = m.asm:match('^(%a+)')
			if BARIER[op] or m.asm:match('PC$') then
				hot = hot:push(spots)
			end
		elseif m.x>0 then hot = newHot():add(i,m) end
	end end 
	if hot then hot = hot:push(spots) end
	
	-- for _,h in pairs(spots) do out('1 %s-%s\n', h.a,h.z) end
    
	-- essaye de faire grossi les plus petits segments
	local function f1(b) return -b.t end
	local function f2(b) return b.t end
	local pool = {}
	for k,h in pairs(spots) do pool[h.a] = h end
	while next(pool) do -- tant que pool pas vide
		-- on trouve le plus petit avec un saut
		local blk
		for _,h in pairs(pool) do blk = (blk and f1(blk)<f1(h)) and blk or h end

		-- out('Found hot=%s (%d) j=%s, b=%s\n', hot.a, hot.x, hot.j or '-', hot.b or '-')
		-- out('>>%s\n', type(hot.j))

		-- choix de la branche "qui vient après" pla pluds empruntée
		local big, small = spots[blk.j], spots[blk.b]
		if big   and (blk.j<blk.z or big.merged)   then big   = nil end -- retrait du big s'il vient avant
		if small and (blk.b<blk.z or small.merged) then small = nil end -- idem avec small
		if (big and f2(big) or 0)<(small and f2(small) or 0) then big,small = small,big end -- choix du plus utilisé
		
		-- merge de la big
		if big then 
			blk:merge(big) 
		else -- on peut pas prolonger ==> retrait du block pool
			pool[blk.a] = nil
		end
	end

    -- cree une liste ordonnée avec les non mergés
    local ret = {}
    for _,h in pairs(spots) do if not h.merged then table.insert(ret, h:compressTrace()) end end
    table.sort(ret, function(a,b) return a.t > b.t end)
    profile:_()
    return ret
end

------------------------------------------------------------------------------
-- analyseur de mémoire
------------------------------------------------------------------------------

local mem = {
    cycles = 0,
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
    a = function(self, asm, cycles, dp)
        local pc = tonumber(self.PC,16)
        asm = trim(asm)
        if asm then local m = self:_get(pc); m.asm,m.cycles,m.dp = asm,cycles,dp end
        return self
    end,
    -- marque les octets "hexa" comme executés "num" fois
    x = function(self,hexa,num)
        local pc = tonumber(self.PC,16)
        self:_get(pc).hex = hexa
        for i=0,hexa:len()/2-1 do local m = self:_get(pc+i); m.x = m.x + num end
        return self
    end,
    -- marque "addr" comme lue depuis le compteur programme courant
    r = function(self, addr, len, stack)
        for i=0,(len or 1)-1 do local m = self:_get(addr+i)
            m.r, m.s = self.PC, m.s or stack
        end
        return self
    end,
    -- marque "addr" comme écrite depuis le compteur programme courant
    w = function(self, addr, len, stack)
        for i=0,(len or 1)-1 do local m = self:_get(addr+i)
            m.w, m.s = self.PC, m.s or stack
        end
        return self
    end,
    -- marque "addr" comme lue/écrit depuis le compteur programme courant
    -- la partie écrite n'est pas changée si elle est écrite ailleurs
    rw = function(self, addr, len, stack)
        for i=0,(len or 1)-1 do local m = self:_get(addr+i)
            m.r, m.w, m.s = self.PC, m.w==NOADDR and self.PC or m.w, stack
        end
        return self
    end,
    RWX = function(self, m)
        if type(m)=='string' then m = tonumber(m,16) end
        if type(m)=='number' then m = self[m] end
        return m and
            (m.x==0      and '-' or 'X')..
            (m.r==NOADDR and '-' or 'R')..
            (m.w==NOADDR and '-' or 'W')..
            (m.s and 'S' or '')
        or
            '---'
    end,
    _stkop     = '* STACK-ZONE *',
    _cycles_hd = 'Total Cycles',
    -- charge un fichier TAB Separated Value (CSV avec des tab)
    loadTSV = function(self, f)
        if f then
            profile:_()
            local _stkop,stkop = self._stkop
            for s in f:lines() do
                local t = {}
                -- s:gsub('([^\t]*)\t?', function(v) table.insert(t, trim(v) or '') return '' end) i=#t
                -- local i=1 for v in s:gmatch('([^\t]*)\t?') do t[i],i = trim(v) or '', i+1 end
                -- for v in s:gmatch('([^\t]*)\t?') do t[#t+1] = trim(v) or '' end
                for v in s:gmatch('([^\t]*)\t?') do table.insert(t, trim(v) or '') end
                -- for v in s:gmatch('([^\t]*)\t?') do rawset(t, #t+1, trim(v) or '') end
                if t[1] and t[1]:match('=[=]*') then break end
                if t[1] == self._cycles_hd then
                    self.cycles = tonumber(t[2]:match('^(%d+)')) or self.cycles
                elseif t[3] and t[1]:match('^%x%x%x%x$') then
                    local pc,r,w,x,h,c,a = unpack(t)
                    -- print(table.concat(t,','))
                    pc = tonumber(pc,16)
                    if a==_stkop then a,stkop = '',true else stkop = nil    end
                    if h         then self:pc(pc):x(h,tonumber(x)):a(a,c)   end
                    if r~=NOADDR then self:pc(tonumber(r,16)):r(pc,1,stkop) end
                    if w~=NOADDR then self:pc(tonumber(w,16)):w(pc,1,stkop) end
                end
            end
            profile:_()
        else
            f = {close=function() end}
        end
        return f
    end,
    _saveHotspot = function(self, writer)
        local spots,total,count = self._hotspots or findHotspots(self),0,0
        profile:_()
        for i,s in ipairs(spots) do total = total + s.t end
        writer:id("hotspots")
        writer:title('Hot spots (runtime: ~%.2fs)', total/1000000)
        writer:header{'*Number','Addr','<*Assembly','<Label','>*#Count','>Percent (Time)      '}
        for i,s in ipairs(spots) do
			if i>1 then writer:row{'', '', '', '', '', ''} end
            local EMPTY='     '
            s.p = s.p or {s.a}
			local x_times = ''
            for j,p in ipairs(s.p) do
				if p==-1 then
					writer:row{'', '....', '...', '', x_times, ''}
				else
					local m = self[tonumber(p,16)]
					local equate_ptn = EQUATES:t(p):gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]','%%%1')		
					local asm = m.asm:gsub(equate_ptn,''):gsub('<%-unreached','') or ''
					-- local taken,addr = asm:match('^([L]?[BJ]%S%S)%s+%$(%x%x%x%x)')
					-- taken = taken=='BRA' or taken=='LBRA' or taken=='JMP' or addr==s.p[j+1]
					-- if addr and not taken then asm = asm..' !' end
					x_times = sprintf('%5d', m.x) -- %5d pour éviter de matcher une adresse (4 chiffres)
					writer:row{
						j==1 and sprintf('  #%-4d',i) or EMPTY,
						p,
						asm,
						EQUATES[p] or '',
						x_times, 
						j==1 and sprintf('%5.2f%% (%.3fs)',  100*s.t/total, s.t/1000000) 
						or EMPTY,
					nil}
				end
            end
            count = count + s.t
            if i>=3 and count >= .8 * total then break end
        end
        writer:footer()
        profile:_()
    end,
    _saveInfos = function(self, writer)
        -- trouve la pile supposée
        local stack
        for i=0,65535 do
            local m=self[i]
            if m and m.s then stack = '$'..hex(i); break end
        end
        local MACH = {
            ['']      = 'All TO/MO',
            [MACH_XX] = 'Unknown',
            [MACH_MO] = 'MO5/MO6',
            [MACH_TO] = 'TO7(70)/TO8/TO9(+)'
        }
        writer:id('info')
        writer:header{'<','<'}
		local cmdLen,cmdLine = 0,''
		for i,s in ipairs(ARGV) do 
			if cmdLen+1+s:len()>=70 then
				cmdLen,cmdLine = 0,cmdLine..' \n'
			elseif i>1 then
				cmdLen,cmdLine = cmdLen+1,cmdLine..' '
			end
			cmdLen,cmdLine = cmdLen+s:len(),cmdLine..s
		end
        writer:row{   'CLI Arguments' , cmdLine}
        writer:row{    'Current Date' , os.date('%Y-%m-%d %H:%M:%S')}
        writer:row{   self._cycles_hd , sprintf('%d (~%.0fs)', self.cycles, self.cycles/1000000)}
        writer:row{    'Machine Type' , MACH[OPT_MACH or '']}
        writer:row{ 'Stack (guessed)' , stack or "n/a"}
        writer:row{   'Start Address' , '$'..hex(OPT_MIN)}
        writer:row{    'Stop Address' , '$'..hex(OPT_MAX)}
        writer:footer()
    end,
    _saveFlatMap = function(self, writer)
        profile:_()

        local VOID=''
        writer:id("flatmap")
        writer:title("Collected addresses")
        writer:header{"=*  Addr ", "=RdFrom", "=WrFrom", ">*ExeCnt", "<Hex code", ">uSec", "<*Asm code         "}

        local n,curr,last_was_blank=0,-1,true
        local function blk()
            if not last_was_blank then
                writer:row{}
                last_was_blank = true
            end
        end
        local function row(row)
            writer:row(row)
            last_was_blank = false
        end
        local function lbl(adr)

        end
        local function u(i)
            if n<=0 then return end
            if n<=3 then
                for i=i-n,i-1 do
                    local adr = hex(i)
                    row{adr, NOADDR, NOADDR, NOCYCL,
                        VOID,
                        VOID,
                        EQUATES[adr] and OPT_EQU and '* ' .. EQUATES[adr] or VOID,
                        nil}
                end
                n = 0
                return
            end
            blk()
            row{sprintf('%d byte%s untouched', n, n>1 and 's' or '')}
            if i<=OPT_MAX then blk() end
            n = 0
        end

        if OPT_EQU and not self[OPT_MIN] then self:pc(OPT_MIN):a('* Start of range') end
        if OPT_EQU and not self[OPT_MAX] then self:pc(OPT_MAX):a('* End of range')   end

        for i=OPT_MIN,OPT_MAX do
            local m=self[i]
            if m then
                -- local mask = ((m.r==NOADDR or m.asm) and 0 or 1) + (m.w==NOADDR and 0 or 2) + (m.x==0 and 0 or 4)
                local mask = ((m.r..m.w==NOADDR..NOADDR or m.asm) and 0 or 1)*0 + (m.x==0 and 0 or 4)

                if mask ~= curr
                or (m.asm and m.r~=NOADDR) -- and nil==self[tonumber(m.r,16)].rel_jmp)
                then blk() end curr = mask
                u(i)

                local adr = hex(i)
                -- local lbl = m.asm
                -- if not lbl and EQUATES[adr] and OPT_EQU then lbl = '* ' .. EQUATES[adr] end
                local asm = m.asm or (m.s and self._stkop)
                if asm then
                    if m.x>0 and OPT_EQU and EQUATES[adr] then row{'*** ' .. EQUATES[adr] .. ' ***'} end
                elseif OPT_EQU and m.x==0 and EQUATES[adr] then
                    asm = '* ' .. EQUATES[adr]
                end
                if m.r~=NOADDR or m.w~=NOADDR or asm then
                    row{adr, m.r, m.w, m.x>0 and m.asm and m.x or NOCYCL,
                        m.hex or VOID,
                        m.cycles or VOID,
                        asm or VOID,
                        nil}
                end
            else
                n = n + 1
            end
        end u(OPT_MAX+1)
        writer:footer()
        profile:_()
    end,
    _save_Memmap = function(self,writer)
        profile:_()
            -- encodage si JS n'est pas supporté par le browser (Lynx, Links)
        local short = {
            ['---' ] = {'-','Untouched byte',''},
            ['--W' ] = {'W','Writen byte',''},
            ['-R-' ] = {'R','Read byte',''},
            ['-RW' ] = {'M','Modified byte',''},
            ['X--' ] = {'X','Code',''},
            ['X-W' ] = {'Z','Modified code','(cool)'},
            ['XR-' ] = {'Y','Entry point',''},
            ['XRW' ] = {'#','Modified entry point','(strange)'},
            ['---S'] = {'*','Untouched stack byte','(weird)'},
            ['--WS'] = {'*','Never read stack byte','(strange)'},
            ['-R-S'] = {'*','Never writen stack byte','(strange)'},
            ['-RWS'] = {'*','Stack byte',''},
            ['X--S'] = {'*','Impossible','(call me)'},
            ['X-WS'] = {'*','Code on stack','(strange)'},
            ['XR-S'] = {'*','Impossible','(call me)'},
            ['XRWS'] = {'*','Code & stack together','(weird)'},
        nil}

        -- pour avoir une table découpée en plusieurs bout (plus facile à lire et à charger)
        local notEmpty = {}
        local function isEmpty(i,j)
            if j then
                for k=i,j do if not isEmpty(k) then return false end end
                return true
            elseif nil~=notEmpty[i] then
                return not notEmpty[i]
            else
                local empty = true
                for j=i*OPT_COLS,i*OPT_COLS+OPT_COLS-1 do
                    if self:RWX(j)~='---' then empty=false; break; end
                end
                notEmpty[i] = not empty
                return empty
            end
        end
        -- affiche une table découpée. On saute par dessus "BLOC' elements vides
        local BLOC = 8
        local cur,top = math.floor(OPT_MIN/OPT_COLS),math.floor(OPT_MAX/OPT_COLS)
        repeat
            -- saute au dessus des lignes vides
            while cur<=top and isEmpty(cur) do cur = cur + 1 end
            if cur>top then break end
            -- on trouve la fin
            local nxt = cur
            repeat nxt = nxt + 1 until nxt>top or isEmpty(nxt,nxt+BLOC)
            -- titre
            writer:id('memmap' .. cur)
            writer:title('Memory map: $%04X -> $%04X', cur*OPT_COLS, nxt*OPT_COLS-1)
            writer:header{'=','<'}
            for j=cur,nxt-1 do
                local c1, c2 = hex(OPT_COLS*j), ''
                for i=0,OPT_COLS-1 do
                    c2 = c2 .. short[self:RWX(OPT_COLS*j+i)][1]
                end
                writer:row{c1, c2}
            end
            writer:footer()
            cur = nxt
        until cur>top

        writer:id('caption')
        writer:title('Caption')
        local code = {}
        for k,_ in pairs(short) do table.insert(code, sprintf('%4s',k)) end
        table.sort(code)
        writer:header{'<*Attr','=Short','<  Description           ','>Comment '}
        for _,k in ipairs(code) do
            writer:row{k, unpack(short[trim(k)])}
        end
        writer:footer()
        profile:_()
    end,
    -- écrit un fichier en utilisant le writer fourni
    save = function(self, writer)
        writer = writer or newParallelWriter()
        self:_saveInfos(writer)
        self:_saveFlatMap(writer) if     OPT_HOT then
        self:_saveHotspot(writer) end if OPT_MAP then
        self:_save_Memmap(writer) end
        return writer
    end
}
if OPT_EQU then
    mem:pc(00000):a('* Start of memory')
    mem:pc(65535):a('* End of memory')
end

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
    a,x = args:match('^,(%-*)([XYUS])$')        if a and x then return add16(reg(x),-a:len()) end
    x,a = args:match(',([XYUS])(%+*)$')         if x then return reg(x) end
    a,x = args:match('^([D]),([XYUS])$')        if a and x then return add16(reg(x),reg(a)) end
    a,x = args:match('^([AB]),([XYUS])$')       if a and x then return add16(reg(x), sex(reg(a))) end
    a,x = args:match('^%$(%x%x),([XYUS])$')     if a and x then return add16(reg(x), sex(tonumber(a,16))) end
    a,x = args:match('^%-$(%x%x),([XYUS])$')    if a and x then return add16(reg(x),-sex(tonumber(a,16))) end
    a,x = args:match('^%$(%x%x%x%x),([XYUS])$') if a and x then return add16(reg(x),tonumber(a,16)) end

    -- PCR
    x   = args:match('^%$(%x%x%x%x),PCR$')      if x then return tonumber(x,16) end

    -- inconnu
    error(args)
end
getaddr = memoize:ret_1(getaddr) -- speedup with meoization

-- Auxiliaire qui marque les adresses pointée par "ptr" comme
-- lues (dir>0) ou écrits (dir<0) en fonction des arguments de
-- l'opération de pile
local function stack(reg, ptr, dir, args)
    local usePC = args:match('PC')
    local stkop = usePC and reg=='S'
    ptr = tonumber(ptr,16)
    local function mk(len)
        if dir>0 then mem:w(ptr, len, stkop) else mem:r(add16(ptr,-len), len, stkop) end
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
    stack(reg, regs:match(reg..'=(%x%x%x%x)'),-1,args)
end
-- écriture depuis la pile "reg"
local function push(reg, args, regs)
    stack(reg,regs:match(reg..'=(%x%x%x%x)'), 1,args)
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
    local function ok(filename)
        local ret, msg = os.rename(filename,filename.."_")
        ret = ret and os.rename(filename.."_",filename)
        return ret
    end
    while not ok(filename) do
        if os.getenv('COMSPEC') then -- windows
            os.execute('ping -n 1 127.0.0.1 >NUL')
        else
            local t=os.clock() + 1
            repeat
                os.execute('ping -n 1 127.0.0.1 >nil')
            until os.clock()>=t
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

    local pc,hexa,opcode,args,regs,regs_next,sig,jmp,curr_pc
    local nomem_asm = {} -- cache des codes hexa ne touchant pas la mémoire (pour aller plus vite)
    local jmp = nil -- pour tracer d'où l'on vient en cas de saut
    local function maybe_indirect()
        if args:sub(1,1)=='[' then
            local a = getaddr(args,regs)
            if a then mem:r(a,2) end
        end
    end
    local DISPATCH = {
        ['???']  = function() opcode = DCMOTO_RESERVED[hexa] or opcode; return true end,
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
    DISPATCH:_(R8,  function() local a = getaddr(args,regs) if a then mem:r(a)   else return true end end)
    DISPATCH:_(W8,  function() local a = getaddr(args,regs) if a then mem:w(a)   else return true end end)
    DISPATCH:_(RW8, function() local a = getaddr(args,regs) if a then mem:rw(a)  else return true end end)
    DISPATCH:_(R16, function() local a = getaddr(args,regs) if a then mem:r(a,2) else return true end end)
    DISPATCH:_(W16, function() local a = getaddr(args,regs) if a then mem:w(a,2) else return true end end)

	local _parse = {}
    local function parse(s)
		s = s:sub(1,42)
		local r = _parse[s]
		if r==nil then
			r = {s:match('(%x+)%s+(%x+)%s+(%S+)%s+(%S*)%s*$')}
			_parse[s] = r 
		end
		return unpack(r)
    end
    -- parse = memoize:ret_n(parse)

    local OK_START,last = set{'0','1','2','3','4','5','6','7','8','9','A','B','C','D','E','F'}
    profile:_()
    for s in f:lines() do
        -- print(s) io.stdout:flush()
        if 50000==num then num = 0
            local txt = sprintf('%6.02f%%', 100*f:seek()/size)
            out('%s%s', txt, string.rep('\b', txt:len()))
        end
        if s:sub(1,4)=='    ' then
            regs_next = s:sub(61,106)
        elseif OK_START[s:sub(1,1)] then
            num,last,pc,hexa,opcode,args = num+1,s,parse(s)--s:sub(1,42):match('(%x+)%s+(%x+)%s+(%S+)%s+(%S*)%s*$')
            -- print(pc,hex,opcode,args)
            -- curr_pc, sig = tonumber(pc,16), hexa
            curr_pc = tonumber(pc,16)
            if jmp then mem:pc(jmp):r(curr_pc) jmp = nil end
                -- if pc~=jmp_skip then mem:pc(jmp):r(curr_pc) end
                -- jmp,jmp_skip = nil
            -- end
            mem:pc(curr_pc):x(hexa,1)
            if REL_JMP[opcode] then
                sig, jmp, mem[curr_pc].rel_jmp = pc..':'..hexa, curr_pc, args
            else
                sig = hexa
            end
            -- sig = REL_BRANCH[hexa] and pc..':'..hexa or hexa
            regs,regs_next = regs_next,s:sub(61,106)
            if nomem_asm[sig] then
                mem:a(nomem_asm[sig][1],nomem_asm[sig][2])
            else
                local f = DISPATCH[opcode]
                local nomem = nil==f or f()
                -- on ne connait le code asm vraiment qu'à la fin
                local asm, cycles =
                    args=='' and opcode or sprintf("%-5s %s", opcode, args),
                    trim(s:sub(43,46))
				local dp = args:match('<%$(%x%x)$') and regs:match('DP=(%x+)') or nil														 
                -- local addr   = args:match('%$(%x%x%x%x)')
                -- local equate = addr and EQUATES:t(addr) or ''
                -- if equate~='' then -- remore duplicate
                    -- protect special chars
                    -- local equate_ptn = equate:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]','%%%1')
                    -- asm = asm:gsub(equate_ptn, '') .. equate
                -- end
                mem:pc(curr_pc):a(asm,cycles,dp)
                -- nomem_asm[sig] = nomem and asm or nomem_asm[sig]
                if nomem then nomem_asm[sig] = {asm,cycles} end
            end
        else
            jmp = nil
        end
    end
    f:close() _parse = nil
    out(string.rep(' ', 10) .. string.rep('\b',10))
    if last then mem.cycles = mem.cycles + tonumber(last:sub(48,57)) end
    profile:_()

    -- nettoyage des branchements conditionnels non pris
    local last_bcc, last_arg
    for i=0,65535 do
        local m = mem[i]
        if m and m.asm then
            if m.r==last_bcc and i~=last_arg then
                -- si on est lu sans venir d'un saut, on retire le flag de lecture
                m.r = NOADDR
            end
            if m.rel_jmp then
                last_bcc  = hex(i)
                last_arg  = tonumber(m.rel_jmp:match('%$(%x%x%x%x)'),16)
                m.asm = (nil==last_arg or mem[last_arg]) and m.asm or m.asm..BRAKET[1].."unreached"..BRAKET[2]
                -- m.rel_jmp = nil
            else
                last_bcc  = nil
                last_arg  = nil
            end
        end
    end

    local mb, time = size/1024/1024, (os.clock() -start_time)
    log('Analyzed %6.3f Mb of trace (%6.3f Mb/s).', mb, mb / time)
end

-- essaye de deviner le type de machine en analysant la valeur de DP dans
-- la trace
local _guess_MACH = {MO=0,TO=0}
local function guess_MACH(TRACE)
    local THR,TYPE = 100000
    log('Trying to determine machine.')
    profile:_()
    local f = assert(io.open(TRACE,'r'))
    for l in f:lines() do
        if     l:match('DP=20') or l:match('DP=A7') then _guess_MACH.MO = _guess_MACH.MO + 1
        elseif l:match('DP=60') or l:match('DP=E7') then _guess_MACH.TO = _guess_MACH.TO + 1 end
        if _guess_MACH.MO + _guess_MACH.TO > THR then
            if _guess_MACH.MO > 2*_guess_MACH.TO then TYPE='MO'; break; end
            if _guess_MACH.TO > 2*_guess_MACH.MO then TYPE='TO'; break; end
        end
    end
    f:close()
    profile:_()
    if TYPE=='MO' then machMO(); EQUATES:ini(); end
    if TYPE=='TO' then machTO(); EQUATES:ini(); end
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
