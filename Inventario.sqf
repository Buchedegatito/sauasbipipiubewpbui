   // =============================================
// CONFIGURACIÓN
// =============================================
RESCUE_ENABLED = true;               // Activar/desactivar el sistema completo
RESCUE_DEBUG = true;                 // Mostrar mensajes de depuración y marcadores
RESCUE_ALLOW_ENEMY = true;           // ¿Deben los enemigos también rescatar a sus compañeros?
RESCUE_ALLOW_FRIENDLY = true;        // ¿Deben los aliados rescatar a sus compañeros?

// Configuración de distancias (en metros)
RESCUE_DETECTION_RADIUS = 70;        // Radio en el que las IA detectan heridos
RESCUE_COVER_SEARCH_RADIUS = 20;     // Radio para buscar cobertura cercana
RESCUE_COMBAT_IGNORE_RADIUS = 15;    // Distancia desde el enemigo para considerar posición segura
RESCUE_MIN_ENEMIES_TO_IGNORE = 3;    // Mínimo de enemigos cercanos para ignorar al herido temporalmente
RESCUE_BUILDING_PRIORITY = true;     // Priorizar SIEMPRE entrar a edificios para rescatar

// Configuración de comportamiento
RESCUE_PRIORITY = 0.9;               // Prioridad del rescate (0-1). Mayor = más probable
RESCUE_TRAITOR_CHANCE = 0.05;        // Probabilidad de que un enemigo "remate" en lugar de rescatar
RESCUE_HEAL_AFTER_RESCUE = true;     // La IA intenta curar después de rescatar
RESCUE_MAX_DRAG_TIME = 180;          // Tiempo máximo de arrastre (segundos) antes de abandonar
RESCUE_COMBAT_CHECK_DELAY = 10;      // Cada cuántos segundos comprobar si es seguro rescatar
RESCUE_RESCUE_ATTEMPTS_MULTIPLIER = 2; // Multiplicador de intentos de rescate
RESCUE_DISABLE_COLLISIONS = true;    // Desactivar colisiones para unidades caídas
RESCUE_STUCK_TIMER = 8;              // Segundos para considerar una unidad como atascada
RESCUE_PATH_CHECK_DISTANCE = 30;     // Distancia para verificar obstáculos en la ruta

// Variables del sistema
RESCUE_RUNNING = false;              // Indica si el sistema está en ejecución
RESCUE_MONITORED_UNITS = [];         // Lista de unidades monitoreadas
RESCUE_ACTIVE_RESCUES = [];          // Rescates actualmente en progreso

// =============================================
// SISTEMA DE RUTAS AVANZADO
// =============================================

// Función para crear una ruta de waypoints optimizada
RESCUE_fnc_crearRutaWaypoints = {
    params ["_unidad", "_inicio", "_destino"];
    
    // Crear un grupo temporal para la navegación si no existe
    private _grupo = _unidad getVariable ["RESCUE_nav_group", grpNull];
    if (isNull _grupo) then {
        _grupo = createGroup (side _unidad);
        [_unidad] joinSilent _grupo;
        _unidad setVariable ["RESCUE_nav_group", _grupo, true];
        _unidad setVariable ["RESCUE_original_group", group _unidad, true];
    };
    
    // Limpiar waypoints existentes
    while {count waypoints _grupo > 0} do {
        deleteWaypoint [_grupo, 0];
    };
    
    // Configurar el comportamiento del grupo
    _grupo setBehaviour "SAFE";
    _grupo setSpeedMode "LIMITED";
    _grupo setCombatMode "GREEN";
    
    // Obtener posiciones de la ruta mediante un algoritmo optimizado
    private _posiciones = [_inicio, _destino, _unidad] call RESCUE_fnc_calcularPosicionesRuta;
    
    // Si no hay posiciones válidas, crear al menos waypoint final
    if (count _posiciones == 0) then {
        _posiciones = [_destino];
    };
    
    // Crear waypoints para cada posición calculada
    {
        private _pos = _x;
        private _index = _forEachIndex;
        private _wp = _grupo addWaypoint [_pos, 0];
        _wp setWaypointType "MOVE";
        
        if (_index == 0) then {
            // Waypoint inicial
            _wp setWaypointPosition [_pos, 0];
            _wp setWaypointCompletionRadius 3;
        } else {
            if (_index == ((count _posiciones) - 1)) then {
                // Waypoint final
                _wp setWaypointPosition [_pos, 0];
                _wp setWaypointCompletionRadius 3;
                _wp setWaypointStatements ["true", "(group this) setVariable ['RESCUE_ruta_completada', true];"];
            } else {
                // Waypoints intermedios
                _wp setWaypointPosition [_pos, 0];
                _wp setWaypointCompletionRadius 2;
            };
        };
    } forEach _posiciones;
    
    // Debug: mostrar puntos de la ruta
    if (RESCUE_DEBUG) then {
        {
            private _pos = _x;
            private _index = _forEachIndex;
            private _marker = createMarker [format ["RESCUE_wp_%1_%2", _unidad call BIS_fnc_netId, _index], _pos];
            _marker setMarkerType "mil_dot";
            _marker setMarkerSize [0.5, 0.5];
            _marker setMarkerColor "ColorBlue";
            _marker setMarkerText format ["WP%1", _index];
            
            // Almacenar para eliminar después
            private _markers = _unidad getVariable ["RESCUE_route_markers", []];
            _markers pushBack _marker;
            _unidad setVariable ["RESCUE_route_markers", _markers];
        } forEach _posiciones;
    };
    
    // Devolver el grupo para referencia
    _grupo
};

// Función para verificar si una posición está libre de objetos
RESCUE_fnc_posicionLibre = {
    params ["_posicion", "_objetos"];
    
    private _libre = true;
    private _minDistancia = 2.5; // Distancia mínima a cualquier objeto
    
    {
        if (_posicion distance _x < _minDistancia) exitWith {
            _libre = false;
        };
    } forEach _objetos;
    
    _libre
};

// Función para verificar si una ruta es clara sin obstrucciones
RESCUE_fnc_rutaLibre = {
    params ["_desde", "_hasta"];
    
    // Verificar que los parámetros sean posiciones válidas y no vectores
    if (typeName _desde != "ARRAY" || typeName _hasta != "ARRAY") exitWith {
        if (RESCUE_DEBUG) then {
            systemChat "RESCUE_fnc_rutaLibre: Parámetros inválidos";
        };
        false
    };
    
    // Elevar posiciones ligeramente
    private _desdeElevado = _desde vectorAdd [0, 0, 0.5];
    private _hastaElevado = _hasta vectorAdd [0, 0, 0.5];
    
    // Comprobar intersecciones directas
    private _libre = !(lineIntersects [AGLToASL _desdeElevado, AGLToASL _hastaElevado, objNull, objNull]);
    
    if (!_libre) then {
        // Comprobar si hay alguna puerta en el camino que podamos atravesar
        private _distancia = _desde distance _hasta;
        private _direccion = _desde vectorFromTo _hasta;
        private _puertas = nearestObjects [_desde, ["Door"], _distancia + 5];
        
        if (count _puertas > 0) then {
            {
                private _puerta = _x;
                private _posPuerta = position _puerta;
                
                // Comprobar si la puerta está entre punto inicial y final
                private _enRuta = false;
                private _dist1 = _desde distance _posPuerta;
                private _dist2 = _hasta distance _posPuerta;
                
                if (_dist1 + _dist2 < _distancia * 1.2) then {
                    _enRuta = true;
                };
                
                if (_enRuta) then {
                    // Si hay una puerta, consideramos que podemos pasar
                    _libre = true;
                };
                if (_libre) exitWith {};
            } forEach _puertas;
        };
    };
    
    _libre
};

// Función mejorada para calcular los puntos de la ruta entre origen y destino
RESCUE_fnc_calcularPosicionesRuta = {
    params ["_inicio", "_destino", "_unidad"];
    
    private _posiciones = [];
    private _distanciaTotal = _inicio distance _destino;
    private _obstaculos = [];
    
    // Recopilar objetos para evitar (no incluimos puertas)
    _obstaculos = nearestObjects [_inicio, ["Building", "House", "Wall", "Fence", "Rock", "Tree"], _distanciaTotal * 1.5] select {
        !(typeOf _x in ["Land_Door", "Land_Door_Pier", "Land_BarGate_F", "House_Door"]) && 
        !((toLower (typeOf _x)) find "door" >= 0)
    };
    
    // Si es una distancia corta, comprobar ruta directa
    if (_distanciaTotal < 15) then {
        // Verificar si hay ruta directa y clara
        private _rutaDirectaLibre = [_inicio, _destino] call RESCUE_fnc_rutaLibre;
        if (_rutaDirectaLibre) then {
            _posiciones = [_destino];
        };
    };
    
    // Si no hay ruta directa o es larga, calcular waypoints intermedios
    if (count _posiciones == 0) then {
        // Determinar cuántos puntos intermedios necesitamos
        private _numPuntos = floor (_distanciaTotal / 10) max 2; // Un punto cada 10 metros, mínimo 2
        
        // Array para almacenar todos los puntos candidatos
        private _puntosCandidatos = [];
        
        // Primera implementación: Calcular múltiples caminos posibles y elegir el mejor
        for "_angulo" from -45 to 45 step 15 do {
            private _rutaCandidata = [];
            private _puntoInicial = _inicio;
            private _exito = true;
            
            for "_i" from 1 to _numPuntos - 1 do {
                private _porcentaje = _i / _numPuntos;
                
                // Calcular posición con ligera curva según ángulo
                private _anguloAjustado = _angulo * (1 - _porcentaje * _porcentaje); // Reducir el ángulo gradualmente
                private _distanciaActual = _distanciaTotal * _porcentaje;
                private _dirBase = [_inicio, _destino] call BIS_fnc_dirTo;
                
                private _pos = _inicio getPos [_distanciaActual, _dirBase + _anguloAjustado];
                
                // Buscar posición libre de obstáculos
                private _intentos = 0;
                private _posicionValida = false;
                
                while {_intentos < 5 && !_posicionValida} do {
                    // Verificar si la posición está libre y es accesible
                    private _posLibre = [_pos, _obstaculos] call RESCUE_fnc_posicionLibre;
                    private _rutaLibre = [_puntoInicial, _pos] call RESCUE_fnc_rutaLibre;
                    
                    if (_posLibre && _rutaLibre) then {
                        _posicionValida = true;
                    } else {
                        // Intentar otra posición cercana
                        _pos = _pos getPos [2 + random 3, random 360];
                        _intentos = _intentos + 1;
                    };
                };
                
                // Si no encontramos posición válida después de varios intentos, marcar esta ruta como fallida
                if (!_posicionValida) then {
                    _exito = false;
                    break;
                };
                
                _rutaCandidata pushBack _pos;
                _puntoInicial = _pos;
            };
            
            // Verificar si podemos llegar al destino desde el último punto
            if (_exito && count _rutaCandidata > 0) then {
                private _ultimoPunto = _rutaCandidata select ((count _rutaCandidata) - 1);
                private _rutaFinalLibre = [_ultimoPunto, _destino] call RESCUE_fnc_rutaLibre;
                
                if (_rutaFinalLibre) then {
                    _rutaCandidata pushBack _destino;
                    _puntosCandidatos pushBack _rutaCandidata;
                };
            };
        };
        
        // Evaluar todas las rutas candidatas y elegir la mejor
        if (count _puntosCandidatos > 0) then {
            // Ordenar por número de puntos (preferir rutas más directas)
            _puntosCandidatos = [_puntosCandidatos, [], {count _x}, "ASCEND"] call BIS_fnc_sortBy;
            _posiciones = _puntosCandidatos select 0;
        };
    };
    
    // Si no hemos encontrado ruta, intentar algo más simple: zigzag alrededor de obstáculos
    if (count _posiciones == 0) then {
        private _puntoActual = _inicio;
        private _distanciaRestante = _distanciaTotal;
        private _dirBase = [_inicio, _destino] call BIS_fnc_dirTo;
        
        while {_distanciaRestante > 10} do {
            // Calcular un punto avanzado en dirección al objetivo
            private _distanciaSegmento = 10 min _distanciaRestante;
            private _puntoSiguiente = _puntoActual getPos [_distanciaSegmento, _dirBase];
            
            // Verificar si es una ruta libre
            private _rutaLibre = [_puntoActual, _puntoSiguiente] call RESCUE_fnc_rutaLibre;
            if (!_rutaLibre) then {
                // Intentar rodear obstáculo
                private _encontrado = false;
                
                for "_desplazamiento" from 5 to 20 step 5 do {
                    for "_angulo" from 30 to 330 step 60 do {
                        private _puntoAlternativo = _puntoActual getPos [_desplazamiento, _dirBase + _angulo];
                        
                        if ([_puntoActual, _puntoAlternativo] call RESCUE_fnc_rutaLibre) then {
                            _puntoSiguiente = _puntoAlternativo;
                            _encontrado = true;
                            break;
                        };
                    };
                    if (_encontrado) exitWith {};
                };
                
                // Si no encontramos ruta, usar dirección al objetivo
                if (!_encontrado) then {
                    _puntoSiguiente = _puntoActual getPos [5, _dirBase];
                };
            };
            
            // Añadir punto y actualizar
            _posiciones pushBack _puntoSiguiente;
            _puntoActual = _puntoSiguiente;
            _distanciaRestante = _puntoActual distance _destino;
            _dirBase = [_puntoActual, _destino] call BIS_fnc_dirTo;
        };
        
        // Añadir destino final
        if (count _posiciones > 0) then {
            _posiciones pushBack _destino;
        } else {
            _posiciones = [_destino];
        };
    };
    
    // Si la ruta es muy larga, reducir puntos
    if (count _posiciones > 10) then {
        private _posicionesReducidas = [];
        private _skip = floor (count _posiciones / 10);
        _skip = _skip max 1;
        
        for "_i" from 0 to (count _posiciones - 1) step _skip do {
            _posicionesReducidas pushBack (_posiciones select _i);
        };
        
        // Asegurar que el destino está incluido
        if ((count _posicionesReducidas == 0) || (_posicionesReducidas select ((count _posicionesReducidas) - 1)) distance _destino > 1) then {
            _posicionesReducidas pushBack _destino;
        };
        
        _posiciones = _posicionesReducidas;
    };
    
    // Asegurar que el primer punto es accesible
    if (count _posiciones > 1) then {
        private _primerPunto = _posiciones select 0;
        private _rutaInicialLibre = [_inicio, _primerPunto] call RESCUE_fnc_rutaLibre;
        
        if (!_rutaInicialLibre) then {
            // Buscar un punto accesible intermedio
            private _direccion = [_inicio, _primerPunto] call BIS_fnc_dirTo;
            private _distancia = _inicio distance _primerPunto;
            private _puntoIntermedio = _inicio getPos [_distancia * 0.5, _direccion];
            
            // Insertar al principio
            _posiciones = [_puntoIntermedio] + _posiciones;
        };
    };
    
    // Limpiar puntos duplicados o muy cercanos entre sí
    if (count _posiciones > 1) then {
        private _posicionesLimpias = [_posiciones select 0];
        
        for "_i" from 1 to (count _posiciones - 1) do {
            private _puntoActual = _posiciones select _i;
            private _puntoAnterior = _posicionesLimpias select ((count _posicionesLimpias) - 1);
            
            if (_puntoActual distance _puntoAnterior > 5) then {
                _posicionesLimpias pushBack _puntoActual;
            };
        };
        
        _posiciones = _posicionesLimpias;
    };
    
    _posiciones
};

// Función para limpiar los waypoints y marcadores
RESCUE_fnc_limpiarRutaWaypoints = {
    params ["_unidad"];
    
    // Eliminar marcadores si existen
    private _markers = _unidad getVariable ["RESCUE_route_markers", []];
    {
        deleteMarker _x;
    } forEach _markers;
    _unidad setVariable ["RESCUE_route_markers", nil];
    
    // Restaurar grupo original si existe
    private _grupoOriginal = _unidad getVariable ["RESCUE_original_group", grpNull];
    if (!isNull _grupoOriginal) then {
        // Eliminar grupo temporal
        private _grupoTemp = _unidad getVariable ["RESCUE_nav_group", grpNull];
        if (!isNull _grupoTemp) then {
            // Limpiar waypoints
            while {count waypoints _grupoTemp > 0} do {
                deleteWaypoint [_grupoTemp, 0];
            };
            
            // Mover unidad de vuelta al grupo original
            [_unidad] joinSilent _grupoOriginal;
            
            deleteGroup _grupoTemp;
        };
        
        _unidad setVariable ["RESCUE_nav_group", nil];
        _unidad setVariable ["RESCUE_original_group", nil];
        _unidad setVariable ["RESCUE_ruta_completada", nil];
    };
};

// =============================================
// DETECCIÓN DE ZONAS SEGURAS
// =============================================

// Función para detectar la dirección de donde viene la amenaza
RESCUE_fnc_detectarDireccionAmenaza = {
    params ["_unidad"];
    
    private _direccionAmenaza = 0;
    private _enemigosCercanos = [];
    
    // Detectar enemigos cercanos
    _enemigosCercanos = _unidad nearEntities ["CAManBase", 200] select {
        alive _x && 
        side _x != side _unidad && 
        !(_x getVariable ["ACE_isUnconscious", false]) &&
        lifeState _x != "INCAPACITATED"
    };
    
    // Calcular dirección si encontramos una amenaza
    if (count _enemigosCercanos > 0) then {
        // Ordenar por distancia
        _enemigosCercanos = [_enemigosCercanos, [], {_unidad distance _x}, "ASCEND"] call BIS_fnc_sortBy;
        private _amenaza = _enemigosCercanos select 0;
        _direccionAmenaza = [_unidad, _amenaza] call BIS_fnc_dirTo;
    };
    
    // Retornar dirección (0 si no hay amenaza detectada)
    _direccionAmenaza
};

// Función para encontrar cobertura cercana (mejorada)
RESCUE_fnc_encontrarCobertura = {
    params ["_rescatador", "_herido"];
    
    private _direccionAmenaza = [_rescatador] call RESCUE_fnc_detectarDireccionAmenaza;
    private _posicionesEvaluadas = [];
    private _posicion = [];
    private _maxDistancia = 15; // Reducida a 15m máximo
    
    // Debug
    if (RESCUE_DEBUG) then {
        systemChat format ["Dirección de amenaza detectada: %1 grados", _direccionAmenaza];
    };
    
    // Primero buscamos coberturas cercanas a máximo 15 metros
    // Buscar edificios cercanos primero (prioridad máxima)
    private _edificios = nearestObjects [position _herido, ["House", "Building"], _maxDistancia];
    
    // Si hay edificios, intentar encontrar posiciones en su interior
    if (count _edificios > 0) then {
        {
            private _edificio = _x;
            private _posiciones = [_edificio] call BIS_fnc_buildingPositions;
            
            if (count _posiciones > 0) then {
                // Verificar cada posición del edificio
                {
                    private _pos = _x;
                    private _puntuacion = 0;
                    
                    // Limitar distancia máxima a considerar
                    if (_herido distance _pos <= _maxDistancia) then {
                        // Verificar si la posición es accesible
                        private _accesible = [position _rescatador, _pos] call RESCUE_fnc_rutaLibre;
                        
                        if (_accesible || ((_rescatador distance _pos) < 10)) then {
                            // Base: Posición dentro de edificio (gran protección)
                            _puntuacion = _puntuacion + 100;
                            
                            // Distancia (preferir cercanas)
                            _puntuacion = _puntuacion - ((_herido distance _pos) * 1.5);
                            
                            // Protección contra dirección de amenaza
                            if (_direccionAmenaza != 0) then {
                                // Calcular ángulo relativo desde la amenaza hacia la posición
                                private _anguloDiferenciaAmenaza = abs ((_direccionAmenaza - ([position _herido, _pos] call BIS_fnc_dirTo)) % 360);
                                if (_anguloDiferenciaAmenaza > 180) then { _anguloDiferenciaAmenaza = 360 - _anguloDiferenciaAmenaza; };
                                
                                // Mayor puntuación si está en dirección opuesta a la amenaza
                                _puntuacion = _puntuacion + ((_anguloDiferenciaAmenaza / 180) * 50);
                            };
                            
                            // Registrar esta posición con su puntuación
                            _posicionesEvaluadas pushBack [_pos, _puntuacion, "building"];
                        };
                    };
                } forEach _posiciones;
            };
        } forEach _edificios;
    };
    
    // Buscar objetos que puedan servir como cobertura (similar al enfoque LAMBS)
    // Primero definimos una lista completa de objetos que pueden servir como cobertura
    private _tiposCobertura = [
        "LandVehicle", "Tank", "Car", "Wall", "Fence", "Rock", "Stone", "Stone_small", 
        "RockArea", "Rocks", "BlockConcrete", "Wreck", "MASH", "Fortress", "Bunker", 
        "Cargo_base_F", "MetalBarrel", "HBarrier", "HeliH", "Cargo_HQ_base_F", 
        "Land_Stone_8m_F", "Land_Stone_4m_F", "Land_Stone_Gate_F", "Land_PierConcrete_01_4m_ladders_F"
    ];
    
    // Variables para medir objetos
    private _objetos = nearestObjects [position _herido, _tiposCobertura, _maxDistancia];
    
    {
        private _objeto = _x;
        
        // Limitar a objetos cercanos
        if (_herido distance _objeto <= _maxDistancia) then {
            // Calcular tamaño mínimo para considerar como cobertura viable
            private _tamanioMinimo = 0.5;
            
            // Usar enfoque inspirado en LAMBS para determinar posición óptima:
            // 1. Verificar tamaño y orientación del objeto
            private _bbr = boundingBoxReal _objeto;
            private _p1 = _bbr select 0;
            private _p2 = _bbr select 1;
            private _ancho = abs ((_p2 select 0) - (_p1 select 0));
            private _largo = abs ((_p2 select 1) - (_p1 select 1));
            private _alto = abs ((_p2 select 2) - (_p1 select 2));
            
            // Si el objeto es lo suficientemente grande (añadido verificación de alto)
            if (_ancho > _tamanioMinimo || _largo > _tamanioMinimo || _alto > 1 || 
                _objeto isKindOf "Rock" || _objeto isKindOf "Stone") then {
                
                // Determinar mejor posición detrás del objeto respecto a amenaza
                private _direccionDesdeAmenaza = _direccionAmenaza;
                if (_direccionDesdeAmenaza == 0) then {
                    // Si no hay amenaza, buscar dirección lejos del combate general
                    private _enemigos = (nearestObjects [position _herido, ["CAManBase"], 100]) select {
                        alive _x && side _x != side _herido
                    };
                    
                    if (count _enemigos > 0) then {
                        private _centroEnemigos = [0,0,0];
                        {
                            _centroEnemigos = _centroEnemigos vectorAdd (position _x);
                        } forEach _enemigos;
                        
                        _centroEnemigos = _centroEnemigos vectorMultiply (1/(count _enemigos));
                        _direccionDesdeAmenaza = [position _herido, _centroEnemigos] call BIS_fnc_dirTo;
                    } else {
                        _direccionDesdeAmenaza = random 360;
                    };
                };
                
                // Calcular la posición óptima según dimensiones del objeto
                private _distanciaAlObjeto = (_ancho max _largo) * 0.75;
                _distanciaAlObjeto = 1 max _distanciaAlObjeto min 3; // Entre 1 y 3 metros
                
                private _posDetras = position _objeto getPos [_distanciaAlObjeto, _direccionDesdeAmenaza];
                
                // Verificar si hay espacio para una unidad y es accesible
                private _haySuficienteEspacio = count (nearestObjects [_posDetras, ["Building", "House", "Wall"], 1]) == 0;
                private _accesible = [position _rescatador, _posDetras] call RESCUE_fnc_rutaLibre;
                
                if (_accesible && _haySuficienteEspacio) then {
                    private _puntuacion = 0;
                    
                    // Calcular puntuación basada en protección y distancia
                    switch (true) do {
                        case (_objeto isKindOf "Tank" || _objeto isKindOf "Car" || _objeto isKindOf "LandVehicle"): { _puntuacion = 80; };
                        case (_objeto isKindOf "Wall" || _objeto isKindOf "Fence"): { _puntuacion = 70; };
                        case (_objeto isKindOf "Rock" || _objeto isKindOf "Stone"): { _puntuacion = 65; };
                        case (_objeto isKindOf "Fortress" || _objeto isKindOf "Bunker"): { _puntuacion = 75; };
                        case (_objeto isKindOf "BlockConcrete" || _objeto isKindOf "HBarrier"): { _puntuacion = 60; };
                        case (_objeto isKindOf "Tree"): { _puntuacion = 40; };
                        default { 
                            // Calcular puntuación basada en tamaño
                            _puntuacion = 30 + (_alto min 5) * 8 + ((_ancho min 5) + (_largo min 5)) * 3;
                        };
                    };
                    
                    // Distancia - Preferir MUY CERCANAS
                    _puntuacion = _puntuacion - ((_herido distance _posDetras) * 2);
                    
                    // Verificar la protección que ofrece contra la amenaza
                    if (_direccionAmenaza != 0) then {
                        // Verificar si el objeto está entre la amenaza y la posición propuesta
                        private _lineaVisual = [AGLToASL _posDetras, AGLToASL (_herido getPos [100, _direccionAmenaza])];
                        private _intersecciones = lineIntersectsSurfaces [_lineaVisual select 0, _lineaVisual select 1, _objeto, objNull, true, 1];
                        
                        if (count _intersecciones > 0) then {
                            _puntuacion = _puntuacion + 30; // Bonus si el objeto realmente bloquea la línea de visión
                        };
                    };
                    
                    // Registrar esta posición
                    _posicionesEvaluadas pushBack [_posDetras, _puntuacion, typeOf _objeto];
                };
            };
        };
    } forEach _objetos;
    
    // Si no hay posiciones viables dentro de 15m, buscar una posición segura lejos del combate
    if (count _posicionesEvaluadas == 0) then {
        // Determinar dirección opuesta al combate o amenaza
        private _dirSegura = if (_direccionAmenaza != 0) then {
            (_direccionAmenaza + 180) % 360; // Dirección opuesta
        } else {
            // Si no hay amenaza específica, buscar alejarse de cualquier enemigo
            private _enemigos = (nearestObjects [position _herido, ["CAManBase"], 100]) select {
                alive _x && side _x != side _herido
            };
            
            if (count _enemigos > 0) then {
                private _centroEnemigos = [0,0,0];
                {
                    _centroEnemigos = _centroEnemigos vectorAdd (position _x);
                } forEach _enemigos;
                
                _centroEnemigos = _centroEnemigos vectorMultiply (1/(count _enemigos));
                ([position _herido, _centroEnemigos] call BIS_fnc_dirTo) + 180;
            } else {
                random 360; // Si no hay enemigos, dirección aleatoria
            };
        };
        
        // Buscar una posición segura a máximo 30m del combate
        private _distanciaSegura = 25 + random 5; // Entre 25 y 30 metros
        private _posSegura = position _herido getPos [_distanciaSegura, _dirSegura];
        
        // Verificar si la posición es accesible, si no buscar una alternativa
        if (!([position _rescatador, _posSegura] call RESCUE_fnc_rutaLibre)) then {
            for "_angulo" from 15 to 345 step 30 do {
                private _dirAlternativa = (_dirSegura + _angulo) % 360;
                private _posAlternativa = position _herido getPos [_distanciaSegura, _dirAlternativa];
                
                if ([position _rescatador, _posAlternativa] call RESCUE_fnc_rutaLibre) then {
                    _posSegura = _posAlternativa;
                    break;
                };
            };
        };
        
        _posicionesEvaluadas pushBack [_posSegura, 10, "fallback_safe_spot"];
    };
    
    // Ordenar por puntuación y tomar la mejor
    _posicionesEvaluadas sort false;
    _posicion = (_posicionesEvaluadas select 0) select 0;
    private _mejorCobertura = (_posicionesEvaluadas select 0) select 1;
    private _tipoCobertura = (_posicionesEvaluadas select 0) select 2;
    
    if (RESCUE_DEBUG) then {
        systemChat format ["Mejor cobertura encontrada: %1 (puntuación: %2), distancia: %3m", _tipoCobertura, _mejorCobertura, round(_herido distance _posicion)];
    };
    
    // Debug: Mostrar todas las posiciones evaluadas
    if (RESCUE_DEBUG) then {
        {
            private _pos = _x select 0;
            private _score = _x select 1;
            private _type = _x select 2;
            
            private _markerCover = createMarker [format ["RESCUE_eval_%1_%2", _herido call BIS_fnc_netId, _forEachIndex], _pos];
            _markerCover setMarkerType "hd_dot";
            _markerCover setMarkerColor "ColorGreen";
            _markerCover setMarkerText format ["%1: %2", _type, round _score];
            
            // Borrar después de un tiempo
            [_markerCover] spawn {
                params ["_marker"];
                sleep 30;
                deleteMarker _marker;
            };
        } forEach _posicionesEvaluadas;
    };
    
    // IMPORTANTE: Verificar que la posición no está demasiado lejos (máximo permitido)
    if (_herido distance _posicion > 30) then {
        // Si está muy lejos, crear una posición más cercana en la misma dirección
        private _direccion = [position _herido, _posicion] call BIS_fnc_dirTo;
        _posicion = position _herido getPos [28, _direccion]; // Limitar a 28m para estar seguro
        
        if (RESCUE_DEBUG) then {
            systemChat "Posición de cobertura muy lejana, limitada a 28 metros.";
        };
    };
    
    // Retornar la mejor posición encontrada
    _posicion
};

// =============================================
// INICIALIZACIÓN DEL SISTEMA
// =============================================

// Función de inicio principal
RESCUE_fnc_inicializar = {
    if (!isServer) exitWith {};
    
    if (RESCUE_RUNNING) exitWith {
        if (RESCUE_DEBUG) then {
            systemChat "Sistema de rescate ya está en ejecución";
        };
    };
    
    RESCUE_RUNNING = true;
    
    // Registrar manejadores de eventos
    ["ace_unconscious", {
        params ["_unit", "_isUnconscious"];
        if (_isUnconscious && {_unit isKindOf "CAManBase"} && {!isPlayer _unit}) then {
            [_unit] call RESCUE_fnc_marcarUnidadIncapacitada;
        };
        
        // Si la unidad recupera la conciencia, restaurar colisiones
        if (!_isUnconscious && {_unit getVariable ["RESCUE_collisions_disabled", false]}) then {
            [_unit] call RESCUE_fnc_restaurarColisiones;
        };
    }] call CBA_fnc_addEventHandler;
    
    // Compatibilidad sin ACE
    addMissionEventHandler ["EntityKilled", {
        params ["_unit", "_killer", "_instigator"];
        if (_unit isKindOf "CAManBase" && !isPlayer _unit) then {
            // Comprobar si realmente está incapacitado y no completamente muerto
            if (alive _unit || lifeState _unit == "INCAPACITATED") then {
                [_unit] call RESCUE_fnc_marcarUnidadIncapacitada;
            };
        };
    }];
    
    // Iniciar bucle principal
    [] spawn RESCUE_fnc_bucleMonitoreo;
    
    if (RESCUE_DEBUG) then {
        systemChat "Sistema de rescate de compañeros caídos iniciado v2.0";
        systemChat "Versión: 2.1 - BuchedegatitoThese - Sistema de rutas mejorado";
    };
};

// Marcar una unidad como incapacitada para que pueda ser rescatada
RESCUE_fnc_marcarUnidadIncapacitada = {
    params ["_unit"];
    
    if (isPlayer _unit) exitWith {}; // No procesar jugadores
    if (_unit in RESCUE_MONITORED_UNITS) exitWith {}; // Ya está siendo monitoreada
    
    RESCUE_MONITORED_UNITS pushBack _unit;
    
    // Almacenar el lado original antes de caer inconsciente
    private _originalSide = side _unit;
    _unit setVariable ["RESCUE_original_side", _originalSide, true];
    
    // Desactivar TODAS las colisiones desde el inicio
    if (RESCUE_DISABLE_COLLISIONS) then {
        // Guardar lista de todas las unidades cercanas para restaurar después
        private _nearUnits = _unit nearEntities ["CAManBase", 100];
        private _disabledCollisionsList = [];
        
        {
            if (_x != _unit) then {
                _unit disableCollisionWith _x;
                _disabledCollisionsList pushBack _x;
            };
        } forEach _nearUnits;
        
        // Guardar lista de unidades para las que se han desactivado colisiones
        _unit setVariable ["RESCUE_units_no_collision", _disabledCollisionsList, true];
        _unit setVariable ["RESCUE_collisions_disabled", true, true];
        
        if (RESCUE_DEBUG) then {
            systemChat format ["Colisiones desactivadas para %1 con %2 unidades", name _unit, count _disabledCollisionsList];
        };
    };
    
    if (RESCUE_DEBUG) then {
        private _marker = createMarker [format ["RESCUE_marker_%1", _unit call BIS_fnc_netId], position _unit];
        _marker setMarkerType "hd_dot";
        _marker setMarkerColor "ColorRed";
        _marker setMarkerText format ["Herido: %1", name _unit];
        
        _unit setVariable ["RESCUE_marker", _marker];
        systemChat format ["Unidad %1 marcada como incapacitada", name _unit];
    };
};

// Restaurar colisiones para una unidad
RESCUE_fnc_restaurarColisiones = {
    params ["_unit"];
    
    if (!(_unit getVariable ["RESCUE_collisions_disabled", false])) exitWith {};
    
    private _disabledCollisionsList = _unit getVariable ["RESCUE_units_no_collision", []];
    
    {
        _unit enableCollisionWith _x;
    } forEach _disabledCollisionsList;
    
    _unit setVariable ["RESCUE_units_no_collision", nil, true];
    _unit setVariable ["RESCUE_collisions_disabled", false, true];
    
    if (RESCUE_DEBUG) then {
        systemChat format ["Colisiones restauradas para %1", name _unit];
    };
};

// MEJORA: Event handler para detectar cuando la unidad arrastrada recupera conciencia
RESCUE_fnc_agregarEventosUnidadArrastrada = {
    params ["_herido", "_rescatador"];
    
    // Event Handler para detectar cambio de estado de ACE unconscious
    private _aceEhId = ["ace_unconscious", {
        params ["_unit", "_isUnconscious"];
        
        // Si la unidad recupera la consciencia y está siendo arrastrada
        if (!_isUnconscious && {_unit getVariable ["RESCUE_being_dragged", false]}) then {
            // Encontrar quién la está arrastrando
            private _dragger = objNull;
            {
                if (_x getVariable ["RESCUE_dragging", false] && {_unit in (attachedObjects _x)}) exitWith {
                    _dragger = _x;
                };
            } forEach (nearestObjects [_unit, ["CAManBase"], 10]);
            
            if (!isNull _dragger) then {
                // Cancelar el arrastre
                [_dragger, _unit] call RESCUE_fnc_cancelarArrastre;
                
                if (RESCUE_DEBUG) then {
                    systemChat format ["%1 ha recuperado la consciencia, arrastre cancelado", name _unit];
                };
            };
        };
    }] call CBA_fnc_addEventHandler;
    
    // Event Handler de revive vanilla
    private _vanillaEhId = _herido addEventHandler ["HandleHeal", {
        params ["_unit", "_healer", "_healerCanHeal"];
        
        if (!(_unit getVariable ["ACE_isUnconscious", false]) && 
            lifeState _unit != "INCAPACITATED" && 
            {_unit getVariable ["RESCUE_being_dragged", false]}) then {
            
            // Encontrar quién la está arrastrando
            private _dragger = objNull;
            {
                if (_x getVariable ["RESCUE_dragging", false] && {_unit in (attachedObjects _x)}) exitWith {
                    _dragger = _x;
                };
            } forEach (nearestObjects [_unit, ["CAManBase"], 10]);
            
            if (!isNull _dragger) then {
                // Cancelar el arrastre
                [_dragger, _unit] call RESCUE_fnc_cancelarArrastre;
                
                if (RESCUE_DEBUG) then {
                    systemChat format ["%1 ha sido curado, arrastre cancelado", name _unit];
                };
            };
        };
    }];
    
    // Añadir EH para detectar si el rescatador cae incapacitado
    private _rescatadorEhId = _rescatador addEventHandler ["HandleDamage", {
        params ["_unit", "_selection", "_damage", "_source", "_projectile", "_hitIndex", "_instigator", "_hitPoint"];
        
        if (_damage >= 0.9 && {_selection == ""} && {_unit getVariable ["RESCUE_dragging", false]}) then {
            // El rescatador está a punto de caer incapacitado
            {
                if (_x getVariable ["RESCUE_being_dragged", false]) then {
                    [_unit, _x] call RESCUE_fnc_cancelarArrastre;
                    
                    if (RESCUE_DEBUG) then {
                        systemChat format ["%1 ha caído incapacitado, arrastre cancelado", name _unit];
                    };
                };
            } forEach (attachedObjects _unit);
        };
        
        // No modificamos el daño, solo lo detectamos
        _damage
    }];
    
    // También agregamos un EH para estado incapacitado usando Dammaged
    private _rescatadorIncapEhId = _rescatador addEventHandler ["Dammaged", {
        params ["_unit", "_selection", "_damage", "_hitIndex", "_hitPoint", "_shooter", "_projectile"];
        
        // Verificar si el rescatador quedó incapacitado por el daño
        if (damage _unit > 0.9 || lifeState _unit == "INCAPACITATED") then {
            if (_unit getVariable ["RESCUE_dragging", false]) then {
                {
                    if (_x getVariable ["RESCUE_being_dragged", false]) then {
                        [_unit, _x] call RESCUE_fnc_cancelarArrastre;
                        
                        if (RESCUE_DEBUG) then {
                            systemChat format ["%1 ha caído incapacitado, arrastre cancelado", name _unit];
                        };
                    };
                } forEach (attachedObjects _unit);
            };
        };
    }];
    
    // Almacenar IDs de eventos
    _herido setVariable ["RESCUE_eventHandlers", [_aceEhId, _vanillaEhId]];
    _rescatador setVariable ["RESCUE_eventHandlers", [_rescatadorEhId, _rescatadorIncapEhId]];
};

// MEJORA: Función para cancelar el arrastre en cualquier momento
RESCUE_fnc_cancelarArrastre = {
    params ["_rescatador", "_herido"];
    
    // Desconectar unidades
    if (!isNull _herido) then {
        // Si el herido está conectado a algo, separarlo
        if (!isNull (attachedTo _herido)) then {
            detach _herido;
        };
        
        // Resetear animación del herido
        [_herido, ""] remoteExec ["switchMove", 0, false];
        _herido setVariable ["RESCUE_being_dragged", false, true];
    };
    
    if (!isNull _rescatador) then {
        // Reactivar colisiones
        if (!isNull _herido) then {
            _rescatador enableCollisionWith _herido;
            _herido enableCollisionWith _rescatador;
        };
        
        // Resetear animación y variables del rescatador
        [_rescatador, ""] remoteExec ["switchMove", 0, false];
        _rescatador enableAI "ANIM";
        _rescatador setVariable ["RESCUE_dragging", false, true];
    };
    
    // Mostrar mensaje debug
    if (RESCUE_DEBUG) then {
        systemChat format ["Arrastre cancelado entre %1 y %2", if (isNull _rescatador) then {"NADIE"} else {name _rescatador}, if (isNull _herido) then {"NADIE"} else {name _herido}];
    };
};

// Bucle principal de monitoreo para iniciar rescates
RESCUE_fnc_bucleMonitoreo = {
    while {RESCUE_RUNNING} do {
        // Limpiar unidades muertas o ya no incapacitadas
        {
            private _unit = _x;
            
            // Si la unidad ya no está incapacitada pero tiene colisiones desactivadas, restaurarlas
            if (!((lifeState _unit == "INCAPACITATED") || (_unit getVariable ["ACE_isUnconscious", false])) && 
                (_unit getVariable ["RESCUE_collisions_disabled", false])) then {
                [_unit] call RESCUE_fnc_restaurarColisiones;
            };
            
        } forEach RESCUE_MONITORED_UNITS;
        
        RESCUE_MONITORED_UNITS = RESCUE_MONITORED_UNITS select {
            alive _x && 
            (lifeState _x == "INCAPACITATED" || 
             (_x getVariable ["ACE_isUnconscious", false]) || 
             !canStand _x)
        };
        
        // Actualizar marcadores de depuración
        if (RESCUE_DEBUG) then {
            {
                private _marker = _x getVariable ["RESCUE_marker", ""];
                if (_marker != "") then {
                    _marker setMarkerPos position _x;
                };
            } forEach RESCUE_MONITORED_UNITS;
        };
        
        // Procesar cada herido para encontrar rescatadores
        {
            private _herido = _x;
            
            // Si no está siendo rescatado, buscar rescatador
            if (!(_herido getVariable ["RESCUE_being_rescued", false])) then {
                // Recuperar el lado original de la unidad
                private _originalSide = _herido getVariable ["RESCUE_original_side", side _herido];
                
                // Encontrar posibles rescatadores
                private _rescatadores = (nearestObjects [_herido, ["CAManBase"], RESCUE_DETECTION_RADIUS]) select {
                    alive _x && 
                    !isPlayer _x && 
                    {(side _x == _originalSide) || (side _x getFriend _originalSide >= 0.6)} && 
                    {canStand _x} && 
                    {!(_x getVariable ["RESCUE_is_rescuing", false])} &&
                    {!(_x getVariable ["ACE_isUnconscious", false])} &&
                    {lifeState _x != "INCAPACITATED"}
                };
                
                // NUEVO: Verificar que no estén ya arrastrando a alguien
                _rescatadores = _rescatadores select {
                    count (attachedObjects _x) == 0
                };
                
                // Filtrar por configuración
                _rescatadores = _rescatadores select {
                    (_x in units group _herido) || // Miembros del mismo grupo
                    (side _x == _originalSide && RESCUE_ALLOW_FRIENDLY) || // Permitir aliados si está activado
                    (side _x != _originalSide && RESCUE_ALLOW_ENEMY) // Permitir enemigos si está activado
                };
                
                if (count _rescatadores > 0) then {
                    // Ordenar por distancia
                    _rescatadores = [_rescatadores, [], {_herido distance _x}, "ASCEND"] call BIS_fnc_sortBy;
                    
                    // Tomar el más cercano
                    private _rescatador = _rescatadores select 0;
                    
                    // Iniciar rescate
                    [_rescatador, _herido] spawn RESCUE_fnc_iniciarRescate;
                };
            };
        } forEach RESCUE_MONITORED_UNITS;
        
        sleep 5;
    };
};

// Función para iniciar un rescate
RESCUE_fnc_iniciarRescate = {
    params ["_rescatador", "_herido"];
    
    // Verificar que el rescatador no esté ya arrastrando a alguien
    if (count (attachedObjects _rescatador) > 0) exitWith {
        if (RESCUE_DEBUG) then {
            systemChat format ["%1 ya está arrastrando a alguien, no puede rescatar a %2", name _rescatador, name _herido];
        };
        // Desmarcar para que otro rescatador pueda intentarlo
        _herido setVariable ["RESCUE_being_rescued", false, true];
    };
    
    // Marcar rescate en progreso
    _herido setVariable ["RESCUE_being_rescued", true, true];
    _rescatador setVariable ["RESCUE_is_rescuing", true, true];
    
    // Registrar el rescate activo
    RESCUE_ACTIVE_RESCUES pushBack [_rescatador, _herido];
    
    if (RESCUE_DEBUG) then {
        systemChat format ["%1 está intentando rescatar a %2", name _rescatador, name _herido];
        
        private _marker = createMarker [format ["RESCUE_rescuer_%1", _rescatador call BIS_fnc_netId], position _rescatador];
        _marker setMarkerType "hd_dot";
        _marker setMarkerColor "ColorGreen";
        _marker setMarkerText format ["Rescatador: %1", name _rescatador];
        _rescatador setVariable ["RESCUE_marker", _marker];
    };
    
    // Comprobar traición (solo para enemigos rescatando)
    private _originalSide = _herido getVariable ["RESCUE_original_side", side _herido];
    
    if (side _rescatador != _originalSide && (random 1) < RESCUE_TRAITOR_CHANCE) then {
        [_rescatador, _herido] spawn RESCUE_fnc_ejecutarTraicion;
    } else {
        // Ejecutar rescate normal
        [_rescatador, _herido] spawn RESCUE_fnc_ejecutarRescate;
    };
};

// Ejecutar traición (matar al herido en lugar de rescatarlo)
RESCUE_fnc_ejecutarTraicion = {
    params ["_rescatador", "_herido"];
    
    if (RESCUE_DEBUG) then {
        systemChat format ["%1 va a traicionar y eliminar a %2", name _rescatador, name _herido];
    };
    
    // Aproximarse al herido
    _rescatador doMove (position _herido);
    _rescatador setSpeedMode "FULL";
    
    // Esperar hasta que esté cerca
    waitUntil {
        sleep 1;
        _rescatador distance _herido < 3 || 
        !alive _rescatador || 
        !alive _herido ||
        !(lifeState _herido == "INCAPACITATED" || (_herido getVariable ["ACE_isUnconscious", false]))
    };
    
    // Si cualquiera murió o el herido ya no está incapacitado, cancelar
    if (!alive _rescatador || 
        !alive _herido || 
        !(lifeState _herido == "INCAPACITATED" || (_herido getVariable ["ACE_isUnconscious", false]))) exitWith {
        [_rescatador, _herido] call RESCUE_fnc_finalizarRescate;
    };
    
    // Ejecutar animación de traición
    _rescatador playMove "Acts_Executioner_Forehand";
    sleep 0.5;
    
    // Matar al herido
    _herido setDamage 1;
    
    if (RESCUE_DEBUG) then {
        systemChat format ["%1 ha eliminado a %2 en lugar de rescatarlo", name _rescatador, name _herido];
    };
    
    // Finalizar rescate
    sleep 2;
    [_rescatador, _herido] call RESCUE_fnc_finalizarRescate;
};

// Ejecutar rescate con animación de arrastre
RESCUE_fnc_ejecutarRescate = {
    params ["_rescatador", "_herido"];
    
    private _startTime = time;
    private _rescateExitoso = false;
    private _posicionCubierta = [];
    
    // Inicializar la variable de recálculos
    _rescatador setVariable ["RESCUE_recalculos", 0];
    
    // Fase 1: Aproximación al herido
    if (RESCUE_DEBUG) then {
        systemChat format ["%1 se acerca a %2 para rescatarlo", name _rescatador, name _herido];
    };
    
    // Hacer que se acerque al herido
    _rescatador disableAI "AUTOCOMBAT";
    _rescatador disableAI "TARGET";
    _rescatador disableAI "AUTOTARGET";
    _rescatador setBehaviour "AWARE";
    _rescatador setCombatMode "WHITE";
    _rescatador doMove (position _herido);
    _rescatador setSpeedMode "FULL";
    
    // Esperar hasta que llegue al herido o muera/aborte
    private _tiempoEspera = 0;
    private _lastStuckPos = [0,0,0];
    private _stuckTimer = 0;
    
    while {_tiempoEspera < 60} do {
        // MEJORA: Verificar si el rescatador o el herido ya no pueden participar en el rescate
        if (!alive _rescatador || !alive _herido) exitWith {};
        
        if (!(_rescatador getVariable ["RESCUE_is_rescuing", false])) exitWith {};
        
        // Si el herido ya no está incapacitado, cancelar
        if (!(lifeState _herido == "INCAPACITATED" || (_herido getVariable ["ACE_isUnconscious", false]))) exitWith {
            if (RESCUE_DEBUG) then {
                systemChat format ["%1 ya no necesita ser rescatado", name _herido];
            };
        };
        
        // Si hay muchos enemigos cerca, abortar temporalmente
        private _enemigos = nearestObjects [_rescatador, ["CAManBase"], RESCUE_COMBAT_IGNORE_RADIUS] select {alive _x && side _x != side _rescatador};
        if (count _enemigos >= RESCUE_MIN_ENEMIES_TO_IGNORE) then {
            if (RESCUE_DEBUG) then {
                systemChat format ["%1 ignora temporalmente al herido para combatir (%2 enemigos cerca)", name _rescatador, count _enemigos];
            };
            _tiempoEspera = _tiempoEspera + 5;
            sleep 5;
            continue;
        };
        
        // Si está cerca, continuar
        if (_rescatador distance _herido < 3) exitWith {
            if (RESCUE_DEBUG) then {
                systemChat format ["%1 ha llegado hasta %2", name _rescatador, name _herido];
            };
        };
        
        // SISTEMA ANTI-ATASCO SIMPLIFICADO
        if (_lastStuckPos distance position _rescatador < 0.1) then {
            _stuckTimer = _stuckTimer + 1;
            
            // Si ha estado atascado, dar pequeños impulsos
            if (_stuckTimer >= RESCUE_STUCK_TIMER) then {
                _rescatador doMove (position _herido);
                _rescatador setVelocity [sin(random 360) * 0.5, cos(random 360) * 0.5, 0];
                _stuckTimer = 0;
                
                if (RESCUE_DEBUG) then {
                    systemChat format ["%1 está atascado, aplicando pequeño impulso", name _rescatador];
                };
            };
        } else {
            _lastStuckPos = position _rescatador;
            _stuckTimer = 0;
        };
        
        // Reenviar la orden de movimiento periódicamente
        if (_tiempoEspera % 5 == 0) then {
            _rescatador doMove (position _herido);
        };
        
        sleep 1;
        _tiempoEspera = _tiempoEspera + 1;
        
        // Actualizar marcador
        if (RESCUE_DEBUG) then {
            private _marker = _rescatador getVariable ["RESCUE_marker", ""];
            if (_marker != "") then {
                _marker setMarkerPos position _rescatador;
            };
        };
    };
    
    // MEJORA: Verificar condiciones para cancelar el rescate
    if (!alive _rescatador || !alive _herido || 
        !(lifeState _herido == "INCAPACITATED" || (_herido getVariable ["ACE_isUnconscious", false])) ||
        !(_rescatador getVariable ["RESCUE_is_rescuing", false])) exitWith {
        
        if (RESCUE_DEBUG) then {
            if (!alive _rescatador) then {systemChat format ["%1 ha muerto, rescate abortado", name _rescatador];};
            if (!alive _herido) then {systemChat format ["%1 ha muerto, rescate abortado", name _herido];};
            if (alive _herido && !(lifeState _herido == "INCAPACITATED" || (_herido getVariable ["ACE_isUnconscious", false]))) then {
                systemChat format ["%1 ya no necesita ser rescatado", name _herido];
            };
        };
        
        [_rescatador, _herido] call RESCUE_fnc_finalizarRescate;
    };
    
    // Fase 2: Buscar cobertura cercana
    _posicionCubierta = [_rescatador, _herido] call RESCUE_fnc_encontrarCobertura;
    
    if (count _posicionCubierta > 0) then {
        if (RESCUE_DEBUG) then {
            systemChat format ["%1 va a llevar a %2 hacia la cobertura", name _rescatador, name _herido];
            
            private _markerCover = createMarker [format ["RESCUE_cover_%1", _herido call BIS_fnc_netId], _posicionCubierta];
            _markerCover setMarkerType "hd_dot";
            _markerCover setMarkerColor "ColorBlue";
            _markerCover setMarkerText "Cobertura";
        };
    } else {
        if (RESCUE_DEBUG) then {
            systemChat format ["%1 no encontró cobertura, quedará junto a %2", name _rescatador, name _herido];
        };
        _posicionCubierta = position _herido;
    };
    
    // Fase 3: Transporte del herido CON ANIMACIÓN
    // Evitar que el motor del juego elimine al herido durante el transporte
    _herido hideObjectGlobal false;
    _herido enableSimulationGlobal true;
    
    // Agacharse para tomar al herido (animación previa)
    _rescatador playMoveNow "AinvPknlMstpSnonWnonDnon_medic4";
    sleep 2;
    
	// MEJORA: Verificar nuevamente condiciones antes de iniciar el arrastre
    if (!alive _rescatador || !alive _herido || 
        !(lifeState _herido == "INCAPACITATED" || (_herido getVariable ["ACE_isUnconscious", false])) ||
        !(_rescatador getVariable ["RESCUE_is_rescuing", false])) exitWith {
        [_rescatador, _herido] call RESCUE_fnc_finalizarRescate;
    };
    
    // Adjuntar herido en una posición específica
    _herido attachTo [_rescatador, [0, 1.1, 0]];
    
    // Desactivar colisiones entre rescatador y herido
    _rescatador disableCollisionWith _herido;
    _herido disableCollisionWith _rescatador;
    
    // Aplicar animación de ser arrastrado al herido
    [_herido, "AinjPpneMrunSnonWnonDb"] remoteExec ["switchMove", 0, false];
    
    // Nos aseguramos que el herido mire en la dirección correcta
    _herido setDir 180;
    
    if (RESCUE_DEBUG) then {
        systemChat format ["Colisiones entre %1 y %2 desactivadas para arrastre", name _rescatador, name _herido];
    };
    
    // Variables para rastrear si está siendo arrastrado
    _herido setVariable ["RESCUE_being_dragged", true, true];
    _rescatador setVariable ["RESCUE_dragging", true, true];
    
    // MEJORA: Agregar event handlers para detectar cuando el herido recupera consciencia o el rescatador cae
    [_herido, _rescatador] call RESCUE_fnc_agregarEventosUnidadArrastrada;
    
    // Agregar manejador de evento para la muerte del rescatador (mantener este también por compatibilidad)
    private _ehID = _rescatador addEventHandler ["Killed", {
        params ["_unit"];
        // Buscar unidades que estén siendo arrastradas por esta unidad
        {
            if (_x getVariable ["RESCUE_being_dragged", false]) then {
                [_unit, _x] call RESCUE_fnc_cancelarArrastre;
            };
        } forEach (attachedObjects _unit);
    }];
    
    // MODIFICACIÓN PARA MEJORAR EL MOVIMIENTO:
    // 1. Cambiar a una animación más compatible con movimiento
    [_rescatador, "AcinPknlMwlkSrasWrflDb"] remoteExec ["switchMove", 0, false];
    
    // 2. Desactivar el control de animación de la IA para evitar interferencia
    _rescatador disableAI "ANIM";
    
    // NUEVO: Usar sistema de waypoints avanzado
    private _grupoWaypoints = [_rescatador, getPos _rescatador, _posicionCubierta] call RESCUE_fnc_crearRutaWaypoints;
    _grupoWaypoints setVariable ["RESCUE_ruta_completada", false];
    
    if (RESCUE_DEBUG) then {
        systemChat format ["%1 está arrastrando a %2 usando sistema de navegación por waypoints", name _rescatador, name _herido];
    };
    
    // Esperar hasta que llegue a la cobertura
    private _tiempoArrastre = 0;
    private _lastCheckTime = time;
    private _rescateExitoso = false;
    private _stuckTimer = 0;
    private _lastWaypointIndex = -1;
    private _tiempoSinAvance = 0;
    
    while {_tiempoArrastre < RESCUE_MAX_DRAG_TIME} do {
        // MEJORA: Verificaciones más robustas durante el arrastre
        if (!alive _rescatador || !alive _herido) exitWith {
            if (RESCUE_DEBUG) then {
                systemChat "Rescate abortado por muerte de una unidad";
            };
            
            // Cancelar arrastre en lugar de finalizar rescate normalmente
            [_rescatador, _herido] call RESCUE_fnc_cancelarArrastre;
        };
        
        // Si el herido ya no está incapacitado, cancelar el arrastre
        if (!(lifeState _herido == "INCAPACITATED" || (_herido getVariable ["ACE_isUnconscious", false]))) exitWith {
            if (RESCUE_DEBUG) then {
                systemChat "Rescate cancelado porque el herido ya no está incapacitado";
            };
            
            // Cancelar arrastre específicamente
            [_rescatador, _herido] call RESCUE_fnc_cancelarArrastre;
        };
        
        // Si el rescatador queda incapacitado, cancelar
        if (lifeState _rescatador == "INCAPACITATED" || (_rescatador getVariable ["ACE_isUnconscious", false])) exitWith {
            if (RESCUE_DEBUG) then {
                systemChat "Rescate abortado porque el rescatador quedó incapacitado";
            };
            
            // Cancelar arrastre
            [_rescatador, _herido] call RESCUE_fnc_cancelarArrastre;
        };
        
        // Si la ruta está completada o está cerca del destino, terminar
        if (_grupoWaypoints getVariable ["RESCUE_ruta_completada", false] || _rescatador distance _posicionCubierta < 3) exitWith {
            _rescateExitoso = true;
            if (RESCUE_DEBUG) then {
                systemChat format ["%1 ha llevado a %2 a una posición segura", name _rescatador, name _herido];
            };
        };
        
        // Verificar periódicamente conexión del herido y actualizar la animación
        if (time - _lastCheckTime > 5) then {
            _lastCheckTime = time;
            
            // Si por alguna razón se desconectó, volver a conectarlo
            if (attachedTo _herido != _rescatador) then {
                detach _herido;
                _herido attachTo [_rescatador, [0, 1.1, 0]];
                _herido setDir 180; // Mantener orientación correcta
                
                // Reactivar animación del herido
                [_herido, "AinjPpneMrunSnonWnonDb"] remoteExec ["switchMove", 0, false];
                
                if (RESCUE_DEBUG) then {
                    systemChat "Reconectando al herido (se había desconectado)";
                };
            };
            
            // Re-aplicar la animación de arrastre por si se ha interrumpido
            [_rescatador, "AcinPknlMwlkSrasWrflDb"] remoteExec ["switchMove", 0, false];
        };
        
        // SISTEMA ANTI-ATASCO PARA WAYPOINTS
        private _currentWaypointIndex = currentWaypoint _grupoWaypoints;
        
        // Verificar si está progresando en los waypoints
        if (_currentWaypointIndex == _lastWaypointIndex) then {
            _tiempoSinAvance = _tiempoSinAvance + 1;
            
            // Si lleva mucho tiempo sin avanzar, recalcular ruta, PERO MÁXIMO 2 VECES!
            private _recalculosRealizados = _rescatador getVariable ["RESCUE_recalculos", 0];
            if (_tiempoSinAvance > 15 && _recalculosRealizados < 2) then {
                // Recalcular ruta desde posición actual
                [_rescatador] call RESCUE_fnc_limpiarRutaWaypoints;
                private _newGrupo = [_rescatador, getPos _rescatador, _posicionCubierta] call RESCUE_fnc_crearRutaWaypoints;
                _newGrupo setVariable ["RESCUE_ruta_completada", false];
                _grupoWaypoints = _newGrupo;
                
                _tiempoSinAvance = 0;
                _lastWaypointIndex = -1;
                
                // Incrementar contador de recálculos
                _rescatador setVariable ["RESCUE_recalculos", _recalculosRealizados + 1];
                
                if (RESCUE_DEBUG) then {
                    systemChat format ["%1 está atascado en los waypoints, recalculando ruta (%2/2)", name _rescatador, _recalculosRealizados + 1];
                };
            };
        } else {
            _lastWaypointIndex = _currentWaypointIndex;
            _tiempoSinAvance = 0;
        };
        
        // Si lleva mucho tiempo arrastrando pero ya ha recalculado 2 veces, considerar exitoso el rescate
        if (_tiempoArrastre > 60 && _rescatador getVariable ["RESCUE_recalculos", 0] >= 2) then {
            _rescateExitoso = true;
            if (RESCUE_DEBUG) then {
                systemChat format ["%1 ha arrastrado suficiente tiempo a %2, considerando rescate exitoso", name _rescatador, name _herido];
            };
            
            // Actualizar marcador de cobertura para mostrar punto final
            private _markerCover = format ["RESCUE_cover_%1", _herido call BIS_fnc_netId];
            if (markerType _markerCover != "") then {
                _markerCover setMarkerPos getPos _rescatador;
            };
            
            break; // Salir del bucle
        };

        // Si lleva poco tiempo pero está muy lejos del destino, hacer un único intento de acercar destino
        if (_tiempoArrastre > 30 && _tiempoArrastre < 50 && _rescatador distance _posicionCubierta > 25) then {
            // Obtener recálculos realizados
            private _recalculosRealizados = _rescatador getVariable ["RESCUE_recalculos", 0];
            
            // Solo hacer esto una vez (si aún no se ha hecho ningún recálculo)
            if (_recalculosRealizados == 0) then {
                // Calcular un punto intermedio entre la posición actual y el destino
                private _dirToDest = [_rescatador, _posicionCubierta] call BIS_fnc_dirTo;
                private _newDest = getPos _rescatador getPos [15, _dirToDest]; // Acercar solo a 15m
                _posicionCubierta = _newDest;
                
                // Recalcular ruta con el nuevo destino (solo una vez)
                [_rescatador] call RESCUE_fnc_limpiarRutaWaypoints;
                private _newGrupo = [_rescatador, getPos _rescatador, _posicionCubierta] call RESCUE_fnc_crearRutaWaypoints;
                _newGrupo setVariable ["RESCUE_ruta_completada", false];
                _grupoWaypoints = _newGrupo;
                
                // Marcar que ya se hizo un recálculo (aunque sea por este motivo)
                _rescatador setVariable ["RESCUE_recalculos", 1];
                
                if (RESCUE_DEBUG) then {
                    systemChat format ["%1 está muy lejos del destino, ajustando a 15m por delante", name _rescatador];
                    
                    // Actualizar marcador de cobertura
                    private _markerCover = format ["RESCUE_cover_%1", _herido call BIS_fnc_netId];
                    if (markerType _markerCover != "") then {
                        _markerCover setMarkerPos _posicionCubierta;
                    };
                };
            };
        };
        
        sleep 1;
        _tiempoArrastre = _tiempoArrastre + 1;
        
        // Actualizar marcador
        if (RESCUE_DEBUG) then {
            private _marker = _rescatador getVariable ["RESCUE_marker", ""];
            if (_marker != "") then {
                _marker setMarkerPos position _rescatador;
            };
        };
    };
    
    // Limpiar la ruta de waypoints
    [_rescatador] call RESCUE_fnc_limpiarRutaWaypoints;
    
    // Limpiar event handlers
    private _ehIds = _rescatador getVariable ["RESCUE_eventHandlers", []];
    {
        if (_forEachIndex == 0) then {
            // El primer ID es para ACE EH
            ["ace_unconscious", _x] call CBA_fnc_removeEventHandler;
        } else {
            _rescatador removeEventHandler [["HandleDamage", "Dammaged"] select (_forEachIndex - 1), _x];
        };
    } forEach _ehIds;
    
    private _heridoEhIds = _herido getVariable ["RESCUE_eventHandlers", []];
    {
        if (_forEachIndex == 0) then {
            // El primer ID es para ACE EH
            ["ace_unconscious", _x] call CBA_fnc_removeEventHandler;
        } else {
            _herido removeEventHandler ["HandleHeal", _x];
        };
    } forEach _heridoEhIds;
    
    // Limpiar el manejador de eventos
    _rescatador removeEventHandler ["Killed", _ehID];
    
    // Restaurar control de animación de la IA
    _rescatador enableAI "ANIM";
    
    // Detener la animación de arrastre y volver a animación normal
    [_rescatador, "amovpknlmstpsraswrfldnon"] remoteExec ["switchMove", 0, false];
    
    // También detener la animación del herido
    [_herido, ""] remoteExec ["switchMove", 0, false];
    
    // Desconectar al herido
    detach _herido;
    _herido setVariable ["RESCUE_being_dragged", false, true];
    _rescatador setVariable ["RESCUE_dragging", false, true];
    
    // Esperar a que la animación termine
    sleep 1;
    
    // Si el rescate fue exitoso, intentar curarlo
    if (_rescateExitoso && RESCUE_HEAL_AFTER_RESCUE && alive _rescatador && alive _herido) then {
        if (RESCUE_DEBUG) then {
            systemChat format ["%1 está intentando curar a %2", name _rescatador, name _herido];
        };
        
        // Animación de curación
        _rescatador playMoveNow "AinvPknlMstpSnonWnonDnon_medic0";
        sleep 6; // Tiempo de curación
        
        // Curar al herido si tiene un kit médico
        if ("Medikit" in (items _rescatador) || "FirstAidKit" in (items _rescatador)) then {
            if ("FirstAidKit" in (items _rescatador)) then {
                _rescatador removeItem "FirstAidKit";
            };
            
            // Hacerlo consciente nuevamente con verificación robusta
            if (isClass (configFile >> "CfgPatches" >> "ace_medical") && !isNil "ace_medical_fnc_setUnconscious") then {
                // Método ACE
                [_herido, false] call ace_medical_fnc_setUnconscious;
            } else {
                // Método vanilla
                _herido setDamage 0.5; // Dejar herido pero consciente
            };
            
            // Restaurar colisiones después de curación
            [_herido] call RESCUE_fnc_restaurarColisiones;
            
            if (RESCUE_DEBUG) then {
                systemChat format ["%1 ha curado con éxito a %2", name _rescatador, name _herido];
            };
        } else {
            if (RESCUE_DEBUG) then {
                systemChat format ["%1 no tiene suministros médicos para curar a %2", name _rescatador, name _herido];
            };
        }; 
    };
    
    // Finalizar el rescate
    [_rescatador, _herido] call RESCUE_fnc_finalizarRescate;
};

// Función para finalizar un rescate
RESCUE_fnc_finalizarRescate = {
    params ["_rescatador", "_herido"];
    
    // Limpiar waypoints y marcadores de ruta
    [_rescatador] call RESCUE_fnc_limpiarRutaWaypoints;
    
    // Asegurarse de que el herido esté desconectado
    if (!isNull _herido && !isNull _rescatador) then {
        // CORRECCIÓN ANTI-ATASCO: Reactivar colisiones al finalizar el arrastre
        _rescatador enableCollisionWith _herido;
        _herido enableCollisionWith _rescatador;
        
        if (RESCUE_DEBUG) then {
            systemChat format ["Colisiones entre %1 y %2 reactivadas", name _rescatador, name _herido];
        };
        
        detach _herido;
    };
    
    // Limpiar variables
    if (!isNull _herido) then {
        _herido setVariable ["RESCUE_being_rescued", false, true];
        _herido setVariable ["RESCUE_being_dragged", false, true];
        
        // Detener animación del herido
        [_herido, ""] remoteExec ["switchMove", 0, false];
    };
    
    if (!isNull _rescatador) then {
        _rescatador setVariable ["RESCUE_is_rescuing", false, true];
        _rescatador setVariable ["RESCUE_dragging", false, true];
        _rescatador setVariable ["RESCUE_recalculos", nil]; // Limpiar contador de recálculos
        
        // Restaurar habilidades de IA
        _rescatador enableAI "AUTOCOMBAT";
        _rescatador enableAI "TARGET";
        _rescatador enableAI "AUTOTARGET";
        _rescatador enableAI "ANIM"; // Restaurar control de animación
        _rescatador setBehaviour "AWARE";
        _rescatador setCombatMode "YELLOW";
    };
    
    // Eliminar de la lista de rescates activos
    RESCUE_ACTIVE_RESCUES = RESCUE_ACTIVE_RESCUES - [[_rescatador, _herido]];
    
    // Limpiar marcadores de depuración
    if (RESCUE_DEBUG) then {
        if (!isNull _rescatador) then {
            private _markerRescuer = _rescatador getVariable ["RESCUE_marker", ""];
            if (_markerRescuer != "") then {
                deleteMarker _markerRescuer;
                _rescatador setVariable ["RESCUE_marker", nil];
            };
        };
        
        private _markerCoverName = format ["RESCUE_cover_%1", _herido call BIS_fnc_netId];
        if (markerType _markerCoverName != "") then {
            deleteMarker _markerCoverName;
        };
    };
};

// Función para limpiar y finalizar el sistema
RESCUE_fnc_finalizar = {
    // Establecer bandera de sistema como inactivo
    RESCUE_RUNNING = false;
    
    // Limpiar marcadores
    {
        if (!isNull _x) then {
            private _marker = _x getVariable ["RESCUE_marker", ""];
            if (_marker != "") then {
                deleteMarker _marker;
            };
        };
    } forEach RESCUE_MONITORED_UNITS;
    
    // Limpiar y restaurar unidades monitoreadas
    {
        if (!isNull _x) then {
            // Restaurar colisiones si están desactivadas
            if (_x getVariable ["RESCUE_collisions_disabled", false]) then {
                [_x] call RESCUE_fnc_restaurarColisiones;
            };
            
            // Limpiar variables de la unidad
            _x setVariable ["RESCUE_being_rescued", nil];
            _x setVariable ["RESCUE_being_dragged", nil];
            _x setVariable ["RESCUE_marker", nil];
            _x setVariable ["RESCUE_original_side", nil];
            
            // Detener animaciones
            [_x, ""] remoteExec ["switchMove", 0, false];
        };
    } forEach RESCUE_MONITORED_UNITS;
    
    // Limpiar rescates activos
    {
        // Usar variables locales para evitar errores
        private _rescatador = _x select 0;
        private _herido = _x select 1;
        
        // Limpiar rescatador
        if (!isNull _rescatador) then {
            // Limpiar ruta de waypoints
            [_rescatador] call RESCUE_fnc_limpiarRutaWaypoints;
            
            // Eliminar variables
            _rescatador setVariable ["RESCUE_is_rescuing", nil];
            _rescatador setVariable ["RESCUE_dragging", nil];
            _rescatador setVariable ["RESCUE_marker", nil];
            _rescatador setVariable ["RESCUE_recalculos", nil];
            
            // Restaurar comportamientos de la IA
            _rescatador enableAI "AUTOCOMBAT";
            _rescatador enableAI "TARGET";
            _rescatador enableAI "AUTOTARGET";
            _rescatador enableAI "ANIM";
            
            // Detener animación
            [_rescatador, ""] remoteExec ["switchMove", 0, false];
        };
        
        // Separar herido de rescatador
        if (!isNull _herido && !isNull _rescatador) then {
            detach _herido;
        };
    } forEach RESCUE_ACTIVE_RESCUES;
    
    // Limpieza final de listas
    RESCUE_MONITORED_UNITS = [];
    RESCUE_ACTIVE_RESCUES = [];
    
    // Mensaje de depuración
    if (RESCUE_DEBUG) then {
        systemChat "Sistema de rescate finalizado correctamente";
    };
};

// =============================================
// INICIALIZAR EL SISTEMA
// =============================================

// Iniciar el sistema al cargar el script
if (RESCUE_ENABLED) then {
    [] spawn {
        sleep 1; // Pequeña pausa para asegurar que todo está listo
        call RESCUE_fnc_inicializar;
    };
};