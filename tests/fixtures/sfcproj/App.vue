<template>
  <div class="app">
    <Widget :count="total" @click="save(total)" />
    <button @click="onCopy">{{ total }}</button>
  </div>
</template>

<script setup lang="ts">
import Widget from './Widget.vue'
import { helperFn } from './util'

const total = 3

function save(n: number) {
  return helperFn(n)
}

function onCopy() {
  return total
}
</script>

<style>
.app { color: red; }
</style>
