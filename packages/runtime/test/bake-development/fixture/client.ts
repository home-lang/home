export const message = 'client-loaded';

document.querySelector('#message')!.textContent = message;
console.log('HOME_BAKE_CLIENT_LOADED');

if (import.meta.hot) {
  import.meta.hot.accept();
}
