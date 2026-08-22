import { Component, computed, inject, input, OnInit, signal } from '@angular/core';
import { ProfileService } from '../../core/services/profile-service';
import { ArticleService } from '../../core/services/article-service';
import { AuthService } from '../../core/auth/auth-service';
import { Article } from '../../core/models/article';
import { Title } from '@angular/platform-browser';
import { RouterLink } from '@angular/router';
import { NgClass } from '@angular/common';
import { ArticlePreviewComponent } from '../../shared/ui/article-preview/article-preview';
import { finalize, tap } from 'rxjs';
import { toObservable } from '@angular/core/rxjs-interop';

@Component({
  selector: 'app-profile',
  imports: [RouterLink, NgClass, ArticlePreviewComponent],
  templateUrl: './profile-page.html',
  styleUrl: './profile-page.css',
})
export class ProfilePage {

  readonly username = input.required<string>();

  private readonly titleService = inject(Title);
  private readonly authService = inject(AuthService);
  private readonly profileService = inject(ProfileService);
  private readonly articleService = inject(ArticleService);

  isCurrentUser = computed(() => {
    return this.profile()?.username === this.authService.currentUser()?.username;
  });
  readonly isLoggedIn = this.authService.isAuthenticated;

  profile = signal<Profile | null>(null);
  articles = signal<Article[]>([]);
  currentTab = signal<'my' | 'favorites'>('my');
  
  constructor() {
    toObservable(this.username).subscribe(() => {
      this.loadProfile();
    });
  }

  setTab(tab: 'my' | 'favorites') {
    this.currentTab.set(tab);
    this.getArticles();
  }

  loadProfile(): void {
    const user = this.username();
    
    // 1. Fetch Profile Info
    this.profileService.get(user).subscribe({
      next: (p: Profile) => {
        this.profile.set(p);
        this.titleService.setTitle(p.username);
        // 2. Once profile is loaded, fetch articles
        this.getArticles(); 
      }
    });
  }

  getArticles() {
    const username = this.username();
    const tab = this.currentTab();

    // Configure query based on tab
    const config = tab === 'my' 
      ? { author: username } 
      : { favorited: username };

    // Assuming your ArticleService has a query method accepting filters
    this.articleService.getArticles(config).subscribe({
      next: (res) => this.articles.set(res.articles),
      error: (err: any) => {
        console.error(err);
      }
    });
  }

  toggleFollow() {
    const p = this.profile();
    if (!p) return;

    // Optimistic Update
    this.profile.update(current => current ? { ...current, following: !current.following } : null);

    const request$ = p.following 
      ? this.profileService.unfollow(p.username)
      : this.profileService.follow(p.username);

    request$.subscribe({
      error: () => {
        // Revert on error
        this.profile.update(current => current ? { ...current, following: p.following } : null);
      }
    });
  }

  toggleFavorite(article: Article) {
    // 1. Calculate the new state immediately
    const isFavorited = article.favorited;
    const newCount = isFavorited ? article.favoritesCount! - 1 : article.favoritesCount! + 1;

    // 2. Optimistically update the Signal (Update the UI instantly)
    // We map over the array, find the matching article, and change only that one
    this.articles.update(currentArticles => 
      currentArticles.map(a => 
        a.slug === article.slug 
          ? { ...a, favorited: !isFavorited, favoritesCount: newCount } 
          : a
      )
    );

    // 3. Send the API request in the background
    const request$ = isFavorited
      ? this.articleService.unfavorite(article.slug!)
      : this.articleService.favorite(article.slug!);

    request$.pipe(
      tap({
        error: (err) => {
          this.articles.update(currentArticles => 
            currentArticles.map(a => 
              a.slug === article.slug 
                ? { ...a, favorited: isFavorited, favoritesCount: article.favoritesCount } 
                : a
            )
          );
        }
      }),
      finalize(() => this.getArticles())
    ).subscribe();
  }
}
