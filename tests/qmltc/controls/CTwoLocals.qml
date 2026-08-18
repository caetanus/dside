// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// DOIS DOCUMENTOS LOCAIS NO MESMO PROCESSO, com os mesmos nomes por dentro.
//
// O compilador guarda o documento actual, a pilha de fontes, a cadeia exterior, os aliases e o
// registo em globais salvos e repostos à volta de `compileObject`. A auditoria pede um
// `CompilationContext` explícito há quatro rondas, e a razão é esta: se uma dessas reposições
// falhar, o estado de um documento aparece no outro — os defeitos históricos de documento errado,
// excerto de fonte e âmbito exterior têm todos essa forma.
//
// O documento de fora NÃO LÊ NADA dos dois, de propósito: ler através de uma instância de tipo
// local é uma lacuna conhecida e faria o fixture falhar por outra razão, medindo outra coisa.
// Cada gémeo calcula a sua largura a partir do SEU `tag` (10+1 e 100+2) e pinta a SUA cor; o
// dumpall compara os filhos com o motor. Se algum estado atravessar, os números trocam-se.
import QtQuick
Item {
    width: 200; height: 60
    CLocalOne { id: a }
    CLocalTwo { id: b; y: 30 }
}
